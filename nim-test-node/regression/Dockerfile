ARG NIM_BUILDPLATFORM=linux/amd64
FROM --platform=${NIM_BUILDPLATFORM} nimlang/nim:2.2.10 AS builder

WORKDIR /node

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    gcc-aarch64-linux-gnu \
    g++-aarch64-linux-gnu \
    ca-certificates \
    curl \
    libssl3 \
    iproute2 \
    procps \
    && rm -rf /var/lib/apt/lists/*

RUN git config --global http.version HTTP/1.1

# fix #1837: honor locked package URLs during installation (#1838)
RUN nimble install -y 'nimble@#07caee397d628c9e93d81048268365c4c2414a80'
ENV PATH="/root/.nimble/bin:${PATH}"

COPY test_node.nimble nimble.lock config.nims ./
RUN nimble refresh && nimble setup

COPY . .

ARG TARGETARCH
ARG NODE_BINARY=node
RUN test "${NODE_BINARY}" = "node" -o "${NODE_BINARY}" = "bootstrap"
RUN case "${TARGETARCH}" in \
        amd64) NIM_TARGET_FLAGS="" ;; \
        arm64) NIM_TARGET_FLAGS="--cpu:arm64 --os:linux --gcc.exe:aarch64-linux-gnu-gcc --gcc.linkerexe:aarch64-linux-gnu-gcc --passL:-lstdc++" ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    nimble c ${NIM_TARGET_FLAGS} \
        -d:chronicles_colors=None --threads:on --mm:refc \
        -d:metrics -d:libp2p_network_protocols_metrics -d:release \
        --out:/node/main \
        "${NODE_BINARY}/main.nim"

FROM debian:bookworm-slim AS runtime

WORKDIR /node

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    libssl3 \
    libgcc-s1 \
    libstdc++6 \
    iproute2 \
    procps \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

COPY --from=builder /node/main /node/main

EXPOSE 5000 8008 8645

ENTRYPOINT ["/node/main"]
