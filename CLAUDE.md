# llama-mali

Mali-G610 OpenCL support for llama.cpp on Orange Pi 5 (RK3588S).

## Goal

Patch llama.cpp's OpenCL backend to recognize and run on ARM Mali-G610 GPU via Mesa Rusticl. The backend currently whitelists only Adreno and Intel GPUs — Mali is rejected.

## Hardware

- **Board**: Orange Pi 5, RK3588S SoC, 16GB LPDDR4X (UMA)
- **GPU**: Mali-G610 MP4 (Valhall, 4 shader cores, subgroup size 16)
- **Driver stack**: Panthor (mainline kernel) + Mesa Rusticl (OpenCL 3.0)
- **Device node**: `/dev/dri/renderD128`

## Development Environment

- Build and test inside Docker: `docker compose run --rm llama-opencl bash`
- GPU passthrough via `/dev/dri`, render group GID 993
- `RUSTICL_ENABLE=panfrost` must be set for OpenCL

## Key Technical Details

- llama.cpp source: find via `find / -name "ggml-opencl.cpp" -path "*/ggml-opencl/*"`
- Build with `-DGGML_OPENCL=ON -DGGML_OPENCL_USE_ADRENO_KERNELS=OFF` (use generic kernel path)
- Mali subgroup size is 16 (vs Adreno 64/128) — kernels must handle this
- UMA hardware: use `CL_MEM_ALLOC_HOST_PTR` with map/unmap, not read/write copies

## Build Commands

```bash
cmake -B build -DGGML_OPENCL=ON -DGGML_OPENCL_USE_ADRENO_KERNELS=OFF -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(nproc)
# Incremental rebuild of just OpenCL target:
cmake --build build --target ggml-opencl -j$(nproc)
```

## Testing

```bash
export RUSTICL_ENABLE=panfrost
./build/bin/llama-bench -m <model.gguf> -ngl 0   # CPU baseline
./build/bin/llama-bench -m <model.gguf> -ngl 99  # GPU offload
```

## Reference

- Full project knowledge base: `knowledge_base/mali-g610-opencl-project.md`
- llama.cpp OpenCL backend: `ggml/src/ggml-opencl/ggml-opencl.cpp`
- OpenCL kernels: `ggml/src/ggml-opencl/kernels/*.cl`
