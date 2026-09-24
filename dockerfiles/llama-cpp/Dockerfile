# llama.cpp, compiled on the machine that runs it.
#
# The published ghcr.io/ggml-org/llama.cpp images are not usable on olympus.
# That host is a pair of LGA2011 Xeons (Sandy/Ivy Bridge-EP): AVX yes, AVX2 and
# FMA no -- AVX2 arrived with Haswell, which is a different socket, so there is
# no upgrade that changes this. The published images either assume AVX2, which
# SIGILLs on the first quantized matmul, or target a generic x86-64 baseline
# that leaves the AVX path unused. Building here with GGML_NATIVE=ON resolves
# the real instruction set once, at build time.
#
# The image is therefore tied to the CPU that built it. Rebuild it if the host
# changes; do not copy it to another machine.

ARG LLAMA_CPP_REF=master

FROM docker.io/library/debian:bookworm-slim AS build
ARG LLAMA_CPP_REF

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        cmake \
        git \
        libcurl4-openssl-dev \
        ninja-build \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --depth 1 --branch "${LLAMA_CPP_REF}" \
        https://github.com/ggml-org/llama.cpp.git .

# GGML_NATIVE defaults to ON upstream. It is named explicitly because it is the
# entire reason this Dockerfile exists rather than a `docker pull`.
RUN cmake -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DGGML_NATIVE=ON \
        -DLLAMA_CURL=ON \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_EXAMPLES=ON \
    && cmake --build build --config Release -j "$(nproc)"

FROM docker.io/library/debian:bookworm-slim AS runtime

# numactl is not decoration: olympus is dual-socket, so every llama.cpp thread
# that lands on the far node pays a QPI hop for weights it streams once per
# token. --numa needs it present to do anything.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libcurl4 \
        libgomp1 \
        numactl \
    && rm -rf /var/lib/apt/lists/*

# Recent llama.cpp emits the shared libs (libllama, libggml*) into bin/ next to
# the executables, so this single copy is the whole runtime.
COPY --from=build /src/build/bin/ /opt/llama.cpp/bin/

ENV PATH=/opt/llama.cpp/bin:$PATH
ENV LD_LIBRARY_PATH=/opt/llama.cpp/bin

EXPOSE 8080

# No ENTRYPOINT on purpose. The same image serves llama-server (the role's
# container) and llama-bench (the evaluation harness); each caller names the
# binary it wants.
CMD ["llama-server", "--help"]
