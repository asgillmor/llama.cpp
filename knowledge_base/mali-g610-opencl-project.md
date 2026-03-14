# Task: Add Mali-G610 OpenCL kernel support to llama.cpp

## Executive Summary

Make llama.cpp's OpenCL backend recognize and dispatch compute to the ARM Mali-G610 GPU via Mesa Rusticl on an Orange Pi 5 (RK3588S). The backend currently has a whitelist-based device detection gate that only accepts Adreno and Intel GPUs — Mali is explicitly rejected. This task involves patching the device detection, adapting kernel subgroup size assumptions from 64/128 (Adreno) to 16 (Mali), and verifying correctness.

**You are running directly on the Orange Pi 5 via Claude Code. You can build, test, and iterate in real-time.**

---

## Hardware and Software Environment

### Hardware
- **Board**: [Orange Pi 5](http://www.orangepi.org/html/hardWare/computerAndMicrocontrollers/details/Orange-Pi-5.html), RK3588S SoC
- **GPU**: Mali-G610 MP4 ([Valhall architecture](https://documentation-service.arm.com/static/660e84991bc22b03bca93008), 4 shader cores)
- **RAM**: 16GB LPDDR4X (UMA — shared between CPU and GPU, ~34 GB/s total bandwidth)
- **Compute**: ~100-200 GFLOPS FP32, ~400 GFLOPS FP16
- **L2 cache**: 1MB shared across cores
- **No dedicated VRAM**: All memory is host-visible

### Software Stack
- **OS**: [Armbian](https://www.armbian.com/) Linux 6.18 (mainline kernel)
- **GPU kernel driver**: [Panthor](https://docs.kernel.org/gpu/panthor.html) (mainline DRM driver for Mali Valhall)
- **OpenCL runtime**: [Mesa 25.2 Rusticl](https://docs.mesa3d.org/rusticl.html) (open-source, NOT the proprietary libmali blob)
- **Device node**: `/dev/dri/renderD128` (standard DRM render node)
- **OpenCL version**: 3.0 via Rusticl
- **Subgroup (warp) size**: 16
- **FP16 support**: Yes
- **No matrix/tensor cores**

### Verification Commands
```bash
# Verify OpenCL device is working
export RUSTICL_ENABLE=panfrost
clinfo
# Should show: Mali-G610 (Panfrost), OpenCL 3.0

# Check device node exists
ls -la /dev/dri/renderD128
```

### llama.cpp Version
- **Release**: b8179 ([releases](https://github.com/ggml-org/llama.cpp/releases))
- **Commit**: bea0200 (February 27, 2026) ([commit](https://github.com/ggml-org/llama.cpp/commit/bea0200))
- **Source**: [node-llama-cpp](https://github.com/withcatai/node-llama-cpp)'s bundled release
- **Location**: Find the llama.cpp source directory on this machine. It may be in a node_modules path under the project, or check common locations.

### What Already Works
- Full inference pipeline runs end-to-end on CPU (embeddings, BM25 search, vector search, cross-encoder reranking)
- llama.cpp compiled with `-DGGML_OPENCL=ON`, produces `libggml-opencl.so`
- OpenCL device detected but rejected: prints `Unsupported GPU: Mali-G610 (Panfrost)`

---

## Container Setup

Before modifying llama.cpp, set up a Docker container for an isolated build environment. The GPU is accessible via the standard DRM render node — no `--privileged` flag needed.

### Dockerfile

```dockerfile
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Build essentials and OpenCL
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    git \
    pkg-config \
    # Mesa Rusticl OpenCL
    mesa-opencl-icd \
    ocl-icd-opencl-dev \
    opencl-headers \
    clinfo \
    # Mesa DRI drivers (includes panfrost/panthor)
    mesa-va-drivers \
    mesa-vulkan-drivers \
    libdrm-dev \
    # Node.js (for node-llama-cpp integration)
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 20 LTS
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Set Rusticl environment
ENV RUSTICL_ENABLE=panfrost

WORKDIR /workspace
```

### Docker Compose (recommended)

```yaml
version: '3.8'
services:
  llama-opencl:
    build: .
    devices:
      - /dev/dri:/dev/dri    # DRM render node for GPU access
    group_add:
      - video                 # Access to /dev/dri/card0
      - render                # Access to /dev/dri/renderD128
    environment:
      - RUSTICL_ENABLE=panfrost
    volumes:
      - ./workspace:/workspace  # Mount your working directory
      - /lib/firmware:/lib/firmware:ro  # Mali firmware (loaded by kernel, but container may need visibility)
    # NO --privileged needed! DRM render nodes work with standard device passthrough
```

### Docker Run (alternative)

```bash
docker build -t llama-mali .
docker run -it --rm \
  --device /dev/dri \
  --group-add video \
  --group-add render \
  -e RUSTICL_ENABLE=panfrost \
  -v $(pwd)/workspace:/workspace \
  -v /lib/firmware:/lib/firmware:ro \
  llama-mali bash
```

### Verify GPU Access Inside Container

```bash
# Inside the container:
clinfo | head -20
# Should show: Mali-G610 (Panfrost), OpenCL 3.0

ls -la /dev/dri/
# Should show: card0, renderD128
```

### Important Notes on Container GPU Access

1. **Panthor vs libmali**: You're using the mainline Panthor kernel driver with Mesa Rusticl (open-source stack). Most RK3588 Docker guides online reference the proprietary libmali blob with `/dev/mali0` — that's a different, older approach. Ignore those guides.

2. **Device nodes**: Panthor exposes the GPU as `/dev/dri/renderD128` (DRM render node). No `/dev/mali0` exists on this system.

3. **Firmware**: The Panthor driver loads [`mali_csffw.bin`](https://github.com/JeffyCN/mirrors/blob/libmali/firmware/g610/mali_csffw.bin) firmware via the kernel. The container doesn't load firmware directly, but mounting `/lib/firmware` read-only ensures the kernel's firmware path works if the driver is reloaded.

4. **Group permissions**: The `render` group (GID varies, often 107 or 109) owns `/dev/dri/renderD128`. If the GIDs don't match between host and container, use `--group-add` with the numeric GID from the host: `stat -c '%g' /dev/dri/renderD128`.

5. **If clinfo shows nothing inside the container**: Verify Mesa Rusticl is installed (`dpkg -l mesa-opencl-icd`), check that the ICD file exists (`ls /etc/OpenCL/vendors/`), and confirm `RUSTICL_ENABLE=panfrost` is set. If the Armbian Mesa packages are newer than Ubuntu 24.04's, you may need to either bind-mount the host's Mesa libraries or use Armbian's package repos inside the container.

6. **Fallback — build on host**: If container GPU passthrough proves problematic, build directly on the host. The container is a nice-to-have for isolation, not a hard requirement.

---

## The OpenCL Backend Architecture (ggml-opencl.cpp)

### Key File Locations

All paths relative to the llama.cpp source root:

- `ggml/src/ggml-opencl/ggml-opencl.cpp` — Backend entry point (~10,000+ lines). Contains:
  - Device detection and GPU whitelist
  - Kernel compilation and dispatch
  - `ggml_opencl_supports_op()` function
  - Buffer allocation and memory management
  - All host-side OpenCL API calls
- `ggml/src/ggml-opencl/kernels/` — OpenCL kernel sources (`.cl` files), split into separate files by [PR #12886](https://github.com/ggml-org/llama.cpp/pull/12886)
- `docs/backend/OPENCL.md` — [Backend documentation](https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/OPENCL.md)

### Device Detection — The Whitelist Gate

During initialization in `ggml_cl2_init()`, the code:

1. Enumerates OpenCL platforms and devices
2. Checks each device name against known patterns
3. **Rejects anything that doesn't match**

The detection logic checks (in order) — refined by [PR #12760](https://github.com/ggml-org/llama.cpp/pull/12760) ("opencl: better identify Adreno GPU," merged April 2025):
- `"Adreno"` in device name → Qualcomm GPU, accepted
- `"Qualcomm"` in device name → Adreno fallback, accepted
- `"Adreno"` in device version string → second Adreno fallback, accepted
- `"Intel"` in device name → Intel GPU, accepted (generic kernel path)
- **Everything else** → prints `"Unsupported GPU: <name>"` and `"ggml_opencl: drop unsupported device."`, falls back to CPU

For Adreno devices, a **secondary parser** extracts the model number (730, 740, 750, 830, X85) and maps it to a wave size (64 or 128). Unrecognized Adreno models default to 128 with a warning.

### How Subgroup Size Is Set

**Critical**: [PR #12886](https://github.com/ggml-org/llama.cpp/pull/12886) changed the backend to **specify subgroup size at compile time** rather than querying it at runtime. The subgroup size is passed as a `-D` preprocessor define when compiling `.cl` kernel sources via `clBuildProgram()`.

The backend uses these OpenCL subgroup operations extensively:
- `sub_group_broadcast` — data exchange within a subgroup
- `sub_group_reduce_add` — parallel reduction within a subgroup

These operations work correctly at any subgroup size, but **tile dimensions and local work group sizes must be multiples of the subgroup size** for correct indexing.

### Adreno Kernel Path vs Generic Path

The backend has two kernel paths controlled by `GGML_OPENCL_USE_ADRENO_KERNELS` (CMake, default ON):

1. **Adreno-optimized path**: Hand-tuned kernels for Qualcomm GPUs with wave sizes 64/128. Uses SOA (Struct of Arrays) weight layout for better memory coalescing. See [Qualcomm's IWOCL 2025 presentation (PDF)](https://www.iwocl.org/wp-content/uploads/iwocl-2025-hongqiang-wang-lamacpp-backend-update.pdf) and [ProAndroidDev writeup](https://proandroiddev.com/introducing-the-new-opencl-gpu-backend-in-llama-cpp-for-qualcomm-adreno-gpus-4093655d334c) for architecture details.
2. **Generic path**: Fallback path for Intel and other GPUs. Less optimized but more portable.

**For Mali, use the generic path**: Build with `-DGGML_OPENCL_USE_ADRENO_KERNELS=OFF`.

### Buffer Allocation and UMA

The backend pre-allocates large intermediate buffers at init time ([~2GB default](https://github.com/ggml-org/llama.cpp/issues/18024) for Adreno). For Mali-G610 on a 16GB system with shared RAM, these defaults are too aggressive. The backend does detect available memory and scales down, but watch for OOM.

Adreno is also UMA (on Snapdragon SoCs), so the backend likely already uses `CL_MEM_ALLOC_HOST_PTR` or SVM buffers rather than explicit host→device copies. This should work for Mali too. If not, the fix is to ensure buffer allocation uses `CL_MEM_ALLOC_HOST_PTR` with `clEnqueueMapBuffer`/`clEnqueueUnmapMemObject` instead of `clEnqueueReadBuffer`/`clEnqueueWriteBuffer`. See [Issue #5965](https://github.com/ggml-org/llama.cpp/issues/5965) for the 13.6× speedup this gave on UMA hardware.

### Supported Operations (ggml_opencl_supports_op)

Located around line 2560. Currently supports for GPU dispatch:
- `GGML_OP_MUL_MAT` — matrix multiplication (primary, heavily optimized for Q4_0)
- `GGML_OP_MUL_MAT_ID` — for MoE models
- `GGML_OP_ADD`, `GGML_OP_MUL` — element-wise ops
- `GGML_OP_RMS_NORM`, `GGML_OP_SOFT_MAX` — normalization
- `GGML_OP_ROPE` — rotary position embeddings
- `GGML_OP_GET_ROWS` — embedding lookups
- `GGML_OP_CPY`, `GGML_OP_CONT`, `GGML_OP_RESHAPE`, `GGML_OP_VIEW`, `GGML_OP_PERMUTE`, `GGML_OP_TRANSPOSE`
- `GGML_OP_FLASH_ATTN_EXT` — flash attention
- `GGML_OP_CONCAT`, `GGML_OP_REPEAT`, `GGML_OP_TANH`, `GGML_OP_SCALE`

Supported quantization types: **Q4_0** (optimized), **Q8_0**, **Q6_K**, MXFP4.

### Quantization Block Sizes

| Type | Block size (QK) | Elements per byte | Block bytes |
|------|----------------|-------------------|-------------|
| Q4_0 | 32 elements | 2 (4-bit) | 18 (16 data + 2 scale) |
| Q8_0 | 32 elements | 1 (8-bit) | 34 (32 data + 2 scale) |

**Key relationship**: QK4_0 = 32 = 2 × Mali's subgroup size of 16. This means each quantization block can be processed by 2 subgroup iterations, which is workable but kernels must handle it correctly.

---

## Implementation Plan

### Approach: Two Stages

**Stage 1 — Get it running (correctness):**
1. Patch device detection to accept Mali
2. Build with generic kernels (`-DGGML_OPENCL_USE_ADRENO_KERNELS=OFF`)
3. Set subgroup size to 16
4. Run `llama-bench` — check for crashes, correct output
5. If crashes, examine which kernel fails and fix subgroup size assumptions

**Stage 2 — Performance tuning (optional, separate session):**
- Reduce buffer pre-allocation for 16GB UMA
- Add Mali-specific kernel variants
- Tune tile sizes for 4 compute units × 16-wide subgroups

### Stage 1 Detailed Steps

#### Step 1: Find the source

```bash
# Find the llama.cpp source. Check common locations:
find / -name "ggml-opencl.cpp" -path "*/ggml-opencl/*" 2>/dev/null
# Also check:
find /home -name "ggml-opencl.cpp" 2>/dev/null
find /opt -name "ggml-opencl.cpp" 2>/dev/null
```

#### Step 2: Understand the current detection gate

```bash
# Find the "Unsupported GPU" string
grep -n "Unsupported GPU" ggml/src/ggml-opencl/ggml-opencl.cpp
grep -n "drop unsupported" ggml/src/ggml-opencl/ggml-opencl.cpp

# Find the device detection logic (look for Adreno/Intel string matching)
grep -n "Adreno\|Qualcomm\|Intel\|gpu_type\|GPU_TYPE" ggml/src/ggml-opencl/ggml-opencl.cpp | head -40

# Find the subgroup/wave size assignment
grep -n "wave_size\|subgroup_size\|SUBGROUP\|sub_group" ggml/src/ggml-opencl/ggml-opencl.cpp | head -30

# Find the GPU type enum
grep -n "enum.*gpu\|GPU_ADRENO\|GPU_INTEL" ggml/src/ggml-opencl/ggml-opencl.cpp | head -20
```

#### Step 3: Add Mali detection

Add a new GPU type and detection branch. The pattern should be:

```cpp
// Pseudocode — adapt to match the actual code structure you find:

// 1. Add to GPU type enum:
GPU_MALI,  // or similar

// 2. Add detection branch (after Adreno, before "Unsupported"):
if (device_name.find("Mali") != std::string::npos ||
    platform_vendor.find("ARM") != std::string::npos ||
    device_name.find("Panfrost") != std::string::npos) {
    gpu_type = GPU_MALI;
    wave_size = 16;  // Mali-G610 subgroup size
    // Log it
    fprintf(stderr, "ggml_opencl: Mali GPU detected: %s, wave size: %d\n",
            device_name.c_str(), wave_size);
}
```

**Important**: The device reports as `"Mali-G610 (Panfrost)"` via Rusticl. Match on `"Mali"` for broad compatibility.

#### Step 4: Build with generic kernels

```bash
cd <llama.cpp source root>

# Clean previous build
rm -rf build

# Configure with generic (non-Adreno) kernels
cmake -B build \
  -DGGML_OPENCL=ON \
  -DGGML_OPENCL_USE_ADRENO_KERNELS=OFF \
  -DCMAKE_BUILD_TYPE=Release

# Build (use all cores, but monitor memory — 16GB shared)
cmake --build build -j$(nproc)

# Or for faster iteration after first build:
cmake --build build --target ggml-opencl -j$(nproc)
```

#### Step 5: Test

```bash
export RUSTICL_ENABLE=panfrost

# Quick sanity test — does it crash?
./build/bin/llama-bench -m <path-to-model.gguf> -ngl 99

# If no model available, just check that the device is now accepted:
# Look for the absence of "Unsupported GPU" and presence of your detection log message
```

#### Step 6: If kernels crash

If specific operations crash, the error will usually indicate which kernel failed. Common issues:

1. **Subgroup size mismatch**: Look for `reqd_work_group_size` attributes in `.cl` files that are multiples of 64 but not 16. Change to multiples of 16.

2. **Local work group size**: Check `clEnqueueNDRangeKernel` calls in `ggml-opencl.cpp`. The local work size must be a multiple of the subgroup size (16).

3. **Tile dimension mismatches**: Look for `#define TILE_M`, `TILE_N`, `TILE_K` values that don't divide evenly by 16.

4. **Subgroup broadcast index out of range**: `sub_group_broadcast(val, lane)` where `lane >= 16` would be invalid on Mali. Search for broadcast calls with hardcoded lane indices > 15.

```bash
# Find potential subgroup size assumptions in kernels:
grep -rn "64\|128\|sub_group_broadcast\|reqd_work_group_size" ggml/src/ggml-opencl/kernels/
```

### Build Time Warning

A full `cmake --build` on the RK3588 takes several minutes. Use incremental builds:

```bash
# After modifying only ggml-opencl.cpp:
cmake --build build --target ggml-opencl -j$(nproc)
# This rebuilds only the changed target, much faster
```

---

## Benchmarking and Validation

### Required: Capture a CPU Baseline FIRST

Before making any code changes, run `llama-bench` in CPU-only mode and save the results. This is your comparison point.

```bash
# Find a GGUF model on the system
find / -name "*.gguf" 2>/dev/null | head -5

# If no model is available, download a small one for testing:
# (If network is available in the container/host)
# Q4_0 TinyLlama (~630MB) — good for quick GPU validation:
# wget https://huggingface.co/ggml-org/models/resolve/main/tinyllamas/stories260K/stories260K.gguf
# Or a slightly larger but more realistic test:
# wget https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_0.gguf

# CPU-only baseline (ngl 0 = no GPU layers)
export RUSTICL_ENABLE=panfrost
./build/bin/llama-bench \
  -m <model.gguf> \
  -ngl 0 \
  -t $(nproc) \
  -o json 2>&1 | tee benchmark_cpu_baseline.json

# Also capture human-readable output
./build/bin/llama-bench \
  -m <model.gguf> \
  -ngl 0 \
  -t $(nproc) 2>&1 | tee benchmark_cpu_baseline.txt
```

`llama-bench` outputs two key metrics:
- **pp** (prompt processing) — tokens/sec for batched input (compute-bound, benefits most from GPU)
- **tg** (token generation) — tokens/sec for autoregressive generation (memory-bandwidth-bound)

### After Each Change: Run the GPU Benchmark

```bash
# GPU benchmark — offload all layers
./build/bin/llama-bench \
  -m <model.gguf> \
  -ngl 99 \
  -t $(nproc) \
  -o json 2>&1 | tee benchmark_gpu_attempt_N.json

# Human-readable
./build/bin/llama-bench \
  -m <model.gguf> \
  -ngl 99 \
  -t $(nproc) 2>&1 | tee benchmark_gpu_attempt_N.txt
```

### Validation: Correctness Check

Performance is meaningless if the output is garbage. After getting GPU dispatch working, verify correctness:

```bash
# Generate text with CPU
./build/bin/llama-cli \
  -m <model.gguf> \
  -ngl 0 \
  -p "The capital of France is" \
  -n 50 \
  --seed 42 2>&1 | tee output_cpu.txt

# Generate text with GPU
./build/bin/llama-cli \
  -m <model.gguf> \
  -ngl 99 \
  -p "The capital of France is" \
  -n 50 \
  --seed 42 2>&1 | tee output_gpu.txt

# Compare — outputs should be identical or very close
# (Minor floating point differences are acceptable, complete gibberish is not)
diff output_cpu.txt output_gpu.txt
```

### Benchmark Progression Log

**Create and maintain a file tracking each benchmark run.** This is the primary deliverable for understanding what worked.

```bash
# Create the log file at the start
cat > benchmark_log.md << 'EOF'
# Mali-G610 OpenCL Benchmark Log

## System
- Board: Orange Pi 5, RK3588S, 16GB
- GPU: Mali-G610 MP4 via Panthor/Rusticl
- Model: <fill in>
- Quantization: <fill in>

## Results

| Run | Change | ngl | pp (t/s) | tg (t/s) | Notes |
|-----|--------|-----|----------|----------|-------|
| 0   | CPU baseline | 0 | ??? | ??? | Before any code changes |
| 1   | Device detection patch | 99 | ??? | ??? | First GPU attempt |
| 2   | ... | ... | ... | ... | ... |

## Correctness
- [ ] CPU output matches GPU output (seed 42, "The capital of France is", 50 tokens)

## Errors Encountered
<log any kernel crashes, CL errors, or build failures here>
EOF
```

**Update this file after every benchmark run.** This is how we track whether the GPU is actually helping.

### What The Numbers Mean

For reference, here's what to expect on this hardware:

| Configuration | pp (t/s) est. | tg (t/s) est. | Source |
|--------------|---------------|----------------|--------|
| CPU-only (8× A76/A55) | 5-15 | 3-8 | Your current baseline |
| Mali-G610 GPU (if working) | 10-30 | 2-6 | MLC-LLM achieved ~2 t/s on 8B Q4 |
| Mali-G610 optimized | 15-40 | 4-8 | Theoretical with tuned kernels |

**Don't be surprised if initial GPU performance is SLOWER than CPU.** The generic kernels aren't tuned for Mali, and kernel compilation overhead on first run is significant. The first goal is correct output, not fast output.

### Partial Offload Testing

If full GPU offload (`ngl 99`) crashes but the device is accepted, try partial offload to isolate which layers work:

```bash
# Offload just 1 layer — tests basic GPU dispatch
./build/bin/llama-bench -m <model.gguf> -ngl 1 2>&1 | tee benchmark_gpu_1layer.txt

# Gradually increase
./build/bin/llama-bench -m <model.gguf> -ngl 5 2>&1 | tee benchmark_gpu_5layers.txt
./build/bin/llama-bench -m <model.gguf> -ngl 10 2>&1 | tee benchmark_gpu_10layers.txt

# Find the sweet spot or the crash point
```

---

## What Success Looks Like

### Minimum Viable (Stage 1)

```
$ RUSTICL_ENABLE=panfrost ./build/bin/llama-bench -m model.gguf -ngl 99

ggml_opencl: Mali GPU detected: Mali-G610 (Panfrost), wave size: 16
ggml_opencl: using generic kernels (non-Adreno)
...
model                | ... | test    | t/s
...                  | ... | tg128   | X.XX   ← any non-zero value = GPU is working
```

No "Unsupported GPU" message. Model loads. Inference produces coherent text matching CPU output. `benchmark_log.md` shows before/after numbers. Performance may be slow initially — that's fine.

### Stretch Goal (Stage 2, separate session)

```
$ RUSTICL_ENABLE=panfrost qmd query "citizenship ancestry" -c reddit-canada -n 5

Embedding 3 queries... (0.3s)     ← GPU accelerated
BM25 + vector search... (1.0s)
Reranking 40 chunks... (6ms)      ← GPU accelerated
Total: ~35s                        ← Down from 3m24s CPU
```

---

## Reference: What Others Have Done

### MLC-LLM on Mali-G610
[MLC-LLM](https://llm.mlc.ai/) runs LLM inference on Mali-G610 via OpenCL using TVM-compiled kernels. They achieved ~2 tok/s on 8B models with:
- Custom OpenCL kernels targeting 16-wide subgroups
- FP16 compute (Mali's FP16 throughput is ~2x FP32)
- Docker containers with `--privileged` (they used the old libmali blob, not Rusticl)
- Blog post: https://blog.mlc.ai/2023/08/09/GPU-Accelerated-LLM-on-Orange-Pi
- Docker reference: https://milas.dev/blog/mali-g610-rk3588-mlc-llm-docker/
- Docker source: https://github.com/milas/rock5-toolchain/blob/main/extra/mlc-llm/Dockerfile

### DCBURG3R/llama.cpp-arm64-opencl
A GitHub fork attempting ARM64 OpenCL support for llama.cpp. Check for relevant patches if stuck.
- https://github.com/DCBURG3R/llama.cpp-arm64-opencl

### Issue #17226
"Why mtk mali GPU not supported?" — closed as "not planned" by maintainers in November 2025. We're doing it ourselves.
- https://github.com/ggml-org/llama.cpp/issues/17226

### Issue #5965 — UMA Memory Performance
"Using OpenCL on Adreno & Mali GPUs is slower than CPU" — identified `CL_MEM_USE_HOST_PTR` copy penalty on UMA. Fix: use `CL_MEM_ALLOC_HOST_PTR` with map/unmap for 13.6× speedup.
- https://github.com/ggml-org/llama.cpp/issues/5965

### Mali-G610 OpenCL Capabilities (from clinfo dump)
- Full dump: https://gist.github.com/tomoaki0705/791f1134212d2bca8e9eaaa3798c0be6
- Max compute units: 4
- Max work group size: 256 (with Rusticl), 512+ (with libmali)
- Max work item sizes: [256, 256, 256]
- Preferred vector width float: 4
- SVM: Coarse grain buffer support (via Rusticl)
- Extensions: cl_khr_fp16, cl_khr_subgroups, cl_khr_global_int32_base_atomics, etc.

### Valhall Shader Core Architecture
ARM's official documentation for the Valhall GPU architecture (Mali-G610, G710, G715, G720):
- https://documentation-service.arm.com/static/660e84991bc22b03bca93008

---

## Key Risks and Mitigations

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Generic kernels assume subgroup ≥ 32 | Medium | Audit `.cl` files for hardcoded 32/64/128 values; fix to use compile-time define |
| Rusticl OpenCL 3.0 missing features llama.cpp needs | Low | Rusticl supports subgroups; check for any extensions used by generic path |
| Buffer pre-allocation OOM on 16GB shared | Medium | Reduce buffer sizes or rely on backend's auto-scaling |
| Container can't access GPU | Low | Fall back to host build; GPU access via `/dev/dri` is well-established |
| Build takes too long for iteration | Medium | Use incremental builds (`--target ggml-opencl`) |
| Kernels compile but produce wrong results | Medium | Compare output with CPU-only run; use small model for quick verification |

---

## All Links

### llama.cpp Core
- **Repository**: https://github.com/ggml-org/llama.cpp
- **Release b8179**: https://github.com/ggml-org/llama.cpp/releases/tag/b8179
- **Commit bea0200**: https://github.com/ggml-org/llama.cpp/commit/bea0200
- **OpenCL backend docs**: https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/OPENCL.md
- **Build docs**: https://github.com/ggml-org/llama.cpp/blob/master/docs/build.md
- **node-llama-cpp**: https://github.com/withcatai/node-llama-cpp

### Key PRs (OpenCL Backend)
- **PR #10693** — Original OpenCL backend (Adreno support): https://github.com/ggerganov/llama.cpp/pull/10693
- **PR #12760** — Better Adreno GPU identification (check "Qualcomm" + device_version): https://github.com/ggml-org/llama.cpp/pull/12760
- **PR #12886** — Split kernels into separate .cl files; specify subgroup size at compile time: https://github.com/ggml-org/llama.cpp/pull/12886
- **PR #14661** — Tracking: additional quant type support for generic OpenCL: https://github.com/ggml-org/llama.cpp/pull/14661
- **PR #15732** — q8_0 matrix-vector multiplication for OpenCL: https://github.com/ggml-org/llama.cpp/pull/15732
- **PR #15800** — Matrix multiply variant for Mali-G715 (may be Vulkan, not OpenCL): https://github.com/ggml-org/llama.cpp/pull/15800

### Key Issues
- **Issue #17226** — "Why mtk mali GPU not supported?" (closed: not planned): https://github.com/ggml-org/llama.cpp/issues/17226
- **Issue #5965** — "Using OpenCL on Adreno & Mali GPUs is slower than CPU" (UMA memory fix): https://github.com/ggml-org/llama.cpp/issues/5965
- **Issue #18024** — 2GB pre-allocation at start (buffer sizing): https://github.com/ggml-org/llama.cpp/issues/18024
- **Issue #14453** — Floating point exception on OpenCL with MoE models: https://github.com/ggml-org/llama.cpp/issues/14453
- **Issue #12810** — OpenCL performance comparison by gpu_offloads: https://github.com/ggml-org/llama.cpp/issues/12810

### Mali-G610 / RK3588 GPU Resources
- **Mali-G610 clinfo dump** (full OpenCL capabilities): https://gist.github.com/tomoaki0705/791f1134212d2bca8e9eaaa3798c0be6
- **Valhall shader core architecture guide** (ARM official): https://documentation-service.arm.com/static/660e84991bc22b03bca93008
- **Mali CSF firmware** (mali_csffw.bin): https://github.com/JeffyCN/mirrors/blob/libmali/firmware/g610/mali_csffw.bin
- **libmali-rockchip releases** (proprietary blob, NOT used here but for reference): https://github.com/tsukumijima/libmali-rockchip/releases

### Mesa / Rusticl / Panthor
- **Rusticl documentation**: https://docs.mesa3d.org/rusticl.html
- **Panthor DRM driver** (kernel docs): https://docs.kernel.org/gpu/panthor.html
- **Panthor driver deep dive** (DeepWiki): https://deepwiki.com/armbian/linux-rockchip/3-panthor-drm-driver
- **Rusticl getting started** (nullr0ute blog): https://nullr0ute.com/2023/12/getting-started-with-opencl-using-mesa-rusticl/

### Community Docker / Mali-G610 LLM Efforts
- **MLC-LLM on Orange Pi** (blog post): https://blog.mlc.ai/2023/08/09/GPU-Accelerated-LLM-on-Orange-Pi
- **Mali-G610 Docker LLM** (milas blog): https://milas.dev/blog/mali-g610-rk3588-mlc-llm-docker/
- **Docker build source** (milas/rock5-toolchain): https://github.com/milas/rock5-toolchain/blob/main/extra/mlc-llm/Dockerfile
- **DCBURG3R llama.cpp ARM64 OpenCL fork**: https://github.com/DCBURG3R/llama.cpp-arm64-opencl
- **Radxa community thread** (Mali OpenCL LLM inference): https://forum.radxa.com/t/mali-opencl-accelerated-llm-inference/18127
- **RK3588 OpenCL setup** (Martin Chang): https://clehaxze.tw/gemlog/2023/06-17-setting-up-opencl-on-rk3588-using-libmali.gmi

### IWOCL 2025 Presentation
- **Qualcomm's llama.cpp OpenCL backend presentation** (Hongqiang Wang, PDF): https://www.iwocl.org/wp-content/uploads/iwocl-2025-hongqiang-wang-lamacpp-backend-update.pdf

### Test Models (GGUF, Q4_0)
- **stories260K** (tiny, ~500KB, for smoke testing): https://huggingface.co/ggml-org/models/resolve/main/tinyllamas/stories260K/stories260K.gguf
- **TinyLlama 1.1B Q4_0** (~630MB, realistic small model): https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_0.gguf

### Hardware
- **Orange Pi 5**: http://www.orangepi.org/html/hardWare/computerAndMicrocontrollers/details/Orange-Pi-5.html
- **RK3588S datasheet** (Rockchip): https://www.rock-chips.com/a/en/products/RK35_Series/2022/0926/1660.html
- **Armbian for Orange Pi 5**: https://www.armbian.com/orangepi-5/

