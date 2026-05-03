# Multi-stage build for nim-lsquic benchmarks
# Stage 1: Build the benchmark binaries
FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl gcc g++ git make xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Install Nim via choosenim
ENV CHOOSENIM_CHOOSE_VERSION=2.2.4
RUN curl https://nim-lang.org/choosenim/init.sh -sSf | bash -s -- -y
ENV PATH="/root/.nimble/bin:${PATH}"

WORKDIR /src

# Copy repo (expects docker build context = repo root)
COPY . .

# Make sure submodules are present
RUN git submodule update --init --recursive 2>/dev/null || true

# Register local package + install deps
RUN nimble develop -y && nimble install -y --depsOnly

# Compile both binaries (--path:/src ensures local lsquic is found)
RUN nim c --threads:on -d:release --path:/src --out:benchmarks/bench_server benchmarks/bench_server.nim
RUN nim c --threads:on -d:release --path:/src --out:benchmarks/bench_client benchmarks/bench_client.nim

# Stage 2: Minimal runtime image
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# iproute2 for tc/netem network shaping
RUN apt-get update && apt-get install -y \
    iproute2 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/benchmarks/bench_server /usr/local/bin/bench_server
COPY --from=builder /src/benchmarks/bench_client /usr/local/bin/bench_client
COPY benchmarks/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
