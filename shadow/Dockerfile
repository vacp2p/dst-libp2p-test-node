# dst-libp2p-test-node — Shadow runner image.
#
# Build from the repo root so this Dockerfile can reach both `shadow/` and `nim-test-node/`:
#   docker buildx build --platform linux/amd64 -f shadow/Dockerfile -t radiken/dst-shadow-nim:latest --push .
#
# Stage 1 builds the same statically-linked nim test-node binary that the k8s
# deployment uses (see nim-test-node/Dockerfile_amd64). Stage 2 installs Shadow
# from source, copies in the prototype topogen/run/awk scripts from shadow/,
# and the main binary from stage 1.

# -----------------------------------------------------------------------------
# Stage 1 — build the nim test-node `main` binary.
# Mirrors nim-test-node/Dockerfile_amd64.
# -----------------------------------------------------------------------------
FROM debian:bookworm-slim AS nim-builder

WORKDIR /node

RUN apt-get update && apt-get install -y \
    curl git build-essential ca-certificates \
    gcc-multilib g++-multilib libc6-dev-i386 \
    libssl3 iproute2 procps xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

RUN git config --global http.sslVerify false

RUN curl https://nim-lang.org/download/nim-2.2.6-linux_x64.tar.xz -o /tmp/nim.tar.xz \
    && tar -xf /tmp/nim.tar.xz -C /tmp \
    && cp -r /tmp/nim-2.2.6/* /usr/local \
    && rm -rf /usr/local/nim* && mv /tmp/nim-2.2.6 /usr/local/nim-2.2.6 \
    && ln -sf /usr/local/nim-2.2.6/bin/nim /usr/local/bin/nim \
    && ln -sf /usr/local/nim-2.2.6/bin/nimble /usr/local/bin/nimble

# Copy only the nim test-node sources (build context is repo root).
COPY nim-test-node/ ./

RUN nimble refresh
RUN nimble install -dy --verbose

# Important: we deliberately DO NOT pass `-static -mmusl -static-libgcc -static-libstdc++`
# here, unlike the k8s test-node build. Shadow's syscall interposition relies on LD_PRELOAD,
# which only works against dynamically linked ELFs — a static binary makes Shadow bail with
# "not a dynamically linked ELF". The trade-off (binary depends on glibc/libssl/etc. on the
# host) is fine because we control the Shadow runner image below.
RUN nimble c \
    --os:linux --cpu:amd64 \
    -d:chronicles_colors=None --threads:on --mm:refc \
    -d:metrics -d:libp2p_network_protocols_metrics -d:release \
    main \
    && chmod +x /node/main

# -----------------------------------------------------------------------------
# Stage 2 — Shadow runner.
# Ubuntu 22.04 is one of Shadow's officially supported platforms.
# -----------------------------------------------------------------------------
FROM ubuntu:22.04 AS runner

ENV DEBIAN_FRONTEND=noninteractive

# Shadow build/runtime deps (from https://shadow.github.io/docs/guide/install_dependencies.html)
# + python3-networkx for topogen.py + awk for the summary scripts.
RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake findutils libclang-dev libc-dbg \
    libglib2.0-0 libglib2.0-dev make netbase \
    python3 python3-networkx python3-yaml xz-utils util-linux \
    gcc g++ git ca-certificates curl gawk \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Shadow v3.x has a Rust workspace, so we need cargo on PATH before building.
ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
ENV PATH="${CARGO_HOME}/bin:/root/.local/bin:${PATH}"
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain stable --profile minimal --no-modify-path \
    && chmod -R a+w ${RUSTUP_HOME} ${CARGO_HOME} \
    && rustc --version

# Build Shadow from source at a pinned tag for reproducibility.
# Bump SHADOW_REF deliberately when picking up a new version.
ARG SHADOW_REF=v3.3.0
RUN git clone --depth 1 --branch ${SHADOW_REF} https://github.com/shadow/shadow.git /tmp/shadow \
    && cd /tmp/shadow \
    && ./setup build --jobs $(nproc) \
    && ./setup install \
    && rm -rf /tmp/shadow

WORKDIR /shadow

# Prototype scripts (topogen.py, run.sh, summary_*.awk).
COPY shadow/ ./
RUN chmod +x ./run.sh

# Statically-linked test node from stage 1.
COPY --from=nim-builder /node/main ./main

# Default args mirror the README's small smoke example. Override via `args:` in the Job manifest.
# usage: run.sh <runs> <nodes> <msg_size> <num_frag> <num_publishers>
#               <min_bw> <max_bw> <min_lat> <max_lat> <steps>
#               <pkt_loss> <publisher_id> <publisher_rotation> <inter_message_delay>
ENTRYPOINT ["./run.sh"]
CMD ["1", "100", "15000", "1", "5", "50", "150", "40", "130", "5", "0.0", "4", "0", "4000"]
