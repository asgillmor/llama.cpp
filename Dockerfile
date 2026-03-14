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

# Install Claude Code
RUN npm install -g @anthropic-ai/claude-code

# Git safe directories (mounted volumes have different ownership)
RUN git config --global --add safe.directory /workspace/llama.cpp \
    && git config --global --add safe.directory /workspace

# Set Rusticl environment
ENV RUSTICL_ENABLE=panfrost

WORKDIR /workspace
