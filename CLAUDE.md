# Mali-G610 OpenCL Backend Work

Fork of llama.cpp for adding Mali-G610 GPU support via OpenCL.
Upstream's AGENTS.md policy does not apply — this is our own fork.

## Reference (read before starting)

Detailed docs are in `../knowledge_base/` (parent repo):
- `auto-mode-workflow.md` — dev loop, parallelization, subagents, pre-commit checks
- `mali-g610-opencl-project.md` — hardware specs, backend architecture, implementation plan
- `llama-cpp-dev-tooling.md` — build system, testing infrastructure, code style

## Quick Reference

- **GPU**: Mali-G610 (Panfrost), OpenCL 3.0, subgroup size 16, 4 compute units
- **16GB shared RAM** (UMA) — watch for OOM
- **Target files**: `ggml/src/ggml-opencl/ggml-opencl.cpp` and `ggml/src/ggml-opencl/kernels/*.cl`
- **Device name**: `"Mali-G610 (Panfrost)"` — match on `"Mali"`
- **Build**: `-DGGML_OPENCL=ON -DGGML_OPENCL_USE_ADRENO_KERNELS=OFF -DGGML_OPENCL_EMBED_KERNELS=OFF`
- **Kernel `.cl` changes don't need a rebuild** (runtime loaded)
- **Commit style**: `opencl: <description>`
- **Cannot git push** from this container (no SSH keys)
