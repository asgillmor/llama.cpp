# Mali-G610 OpenCL Backend Work

This is a fork of llama.cpp for adding Mali-G610 GPU support via OpenCL.
Upstream's AGENTS.md policy does not apply here — this is our own fork.

## Project Context

Full knowledge base is at `../knowledge_base/` (parent repo mount at `/workspace`):
- `mali-g610-opencl-project.md` — hardware specs, implementation plan, reference links
- `llama-cpp-dev-tooling.md` — build system, testing, code style
- `auto-mode-workflow.md` — detailed auto mode workflow and parallelization guide
- `completed-work.md` — log of completed work

## Quick Reference

- **GPU**: Mali-G610 (Panfrost), OpenCL 3.0, subgroup size 16, 4 compute units
- **Hardware**: Orange Pi 5, RK3588S, 16GB shared RAM (UMA)
- **Target files**: `ggml/src/ggml-opencl/ggml-opencl.cpp` and `ggml/src/ggml-opencl/kernels/*.cl`
- **Device name**: `"Mali-G610 (Panfrost)"` — match on `"Mali"`

## Build

```bash
# First time only:
cmake -B build \
  -DGGML_OPENCL=ON \
  -DGGML_OPENCL_USE_ADRENO_KERNELS=OFF \
  -DGGML_OPENCL_EMBED_KERNELS=OFF \
  -DCMAKE_BUILD_TYPE=Release

# Incremental rebuild (.cpp changes only):
cmake --build build --target ggml-opencl -j$(nproc)

# Build specific tools when needed:
cmake --build build --target llama-bench -j$(nproc)
cmake --build build --target test-backend-ops -j$(nproc)
```

Kernel `.cl` files are loaded at runtime (EMBED_KERNELS=OFF) — no rebuild needed for kernel changes.

## Development Loop

```
edit → build (if .cpp changed) → run/test → commit (if it works)
                                           → diagnose & fix (if it fails)
```

1. Batch related edits before building — builds are slow on this hardware
2. Use incremental builds (`--target ggml-opencl`)
3. Commit after successful build+test, never broken code
4. One logical change per commit
5. Commit style: `opencl: <description>`

## Testing (escalate incrementally)

1. Build succeeds
2. Device accepted (no "Unsupported GPU" message)
3. `./build/bin/test-backend-ops` — kernel correctness
4. `./build/bin/llama-bench -m <model> -ngl 1` — minimal GPU offload
5. `./build/bin/llama-bench -m <model> -ngl 99` — full offload
6. `./build/bin/llama-cli -m <model> -ngl 99 -p "The capital of France is" -n 50 --seed 42` — correctness vs CPU

## Before Committing

- Run `clang-format -i` on changed C/C++ files
- No trailing whitespace, newline at EOF
- No binaries or build artifacts in git

## Subagents

Use subagents for **reading and research only** — never for building or testing (GPU/build directory contention). Good for: parallel kernel audits, grepping patterns, reading multiple files.

## Constraints

- Cannot `git push` (no SSH keys in this container)
- 16GB RAM shared between CPU and GPU — watch for OOM
- `RUSTICL_ENABLE=panfrost` is already set
