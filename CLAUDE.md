# llama-mali

Mali-G610 OpenCL support for llama.cpp on Orange Pi 5 (RK3588S).

## Goal

Patch llama.cpp's OpenCL backend to recognize and run on ARM Mali-G610 GPU via Mesa Rusticl. The backend currently whitelists only Adreno and Intel GPUs — Mali is rejected.

## Repo Structure

- `llama.cpp/` — git submodule pointing at `asgillmor/llama.cpp` fork, `mali-g610` branch
- `knowledge_base/` — detailed project context and research
- `Dockerfile` + `docker-compose.yaml` — isolated build/test environment with GPU passthrough

### Git Workflow

- **This repo** (`llama-mali`): project scaffolding, Docker config, knowledge base
- **llama.cpp submodule** (`asgillmor/llama.cpp`): all code changes go here on the `mali-g610` branch
- Commits to llama.cpp are isolated in the fork — upstream's AGENTS.md policy about AI-generated PRs applies only if we ever submit upstream; it does not constrain work on our fork
- SSH deploy keys are per-repo (see `~/.ssh/config` for host aliases `github-llama-mali` and `github-llama-cpp`)

## Hardware

- **Board**: Orange Pi 5, RK3588S SoC, 16GB LPDDR4X (UMA — shared CPU/GPU memory)
- **GPU**: Mali-G610 MP4 (Valhall architecture, 4 shader cores, subgroup size 16)
- **Driver stack**: Panthor (mainline kernel) + Mesa 25.2 Rusticl (OpenCL 3.0)
- **Device node**: `/dev/dri/renderD128`, render group GID 993
- **No dedicated VRAM** — all memory is host-visible

## Development Environment

- Build and test inside Docker: `docker compose run --rm llama-opencl bash`
- GPU passthrough via `/dev/dri`, render group GID 993
- `RUSTICL_ENABLE=panfrost` must be set for OpenCL
- Claude Code runs inside the container in auto mode for uninterrupted iteration

## Key Technical Details

- OpenCL backend source: `llama.cpp/ggml/src/ggml-opencl/ggml-opencl.cpp`
- OpenCL kernels: `llama.cpp/ggml/src/ggml-opencl/kernels/*.cl`
- Build with `-DGGML_OPENCL=ON -DGGML_OPENCL_USE_ADRENO_KERNELS=OFF` (use generic kernel path, not Adreno-optimized)
- Mali subgroup size is 16 (vs Adreno 64/128) — kernels and work group sizes must be multiples of 16
- UMA hardware: use `CL_MEM_ALLOC_HOST_PTR` with map/unmap, not read/write buffer copies
- Device reports as `"Mali-G610 (Panfrost)"` — match on `"Mali"` for detection

## Build Commands

```bash
# Inside the Docker container, from /workspace/llama.cpp:
cmake -B build -DGGML_OPENCL=ON -DGGML_OPENCL_USE_ADRENO_KERNELS=OFF -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(nproc)

# Incremental rebuild of just OpenCL target (faster iteration):
cmake --build build --target ggml-opencl -j$(nproc)
```

## Testing

```bash
export RUSTICL_ENABLE=panfrost

# CPU baseline (always capture first)
./build/bin/llama-bench -m <model.gguf> -ngl 0 -t $(nproc)

# GPU offload
./build/bin/llama-bench -m <model.gguf> -ngl 99 -t $(nproc)

# Correctness: compare CPU vs GPU output
./build/bin/llama-cli -m <model.gguf> -ngl 0 -p "The capital of France is" -n 50 --seed 42
./build/bin/llama-cli -m <model.gguf> -ngl 99 -p "The capital of France is" -n 50 --seed 42
```

## Reference

- Full project knowledge base: `knowledge_base/mali-g610-opencl-project.md`
