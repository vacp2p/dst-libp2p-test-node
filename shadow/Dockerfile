# Shadow runner image.
#
# Ubuntu 22.04 + Shadow built from source + the pod-api-requester (the in-Shadow
# traffic publisher, run by the `publisher` host in batch mode).
# No nim test-node binary baked in: per-experiment dynamic test-node images
# (built from nim-test-node/Dockerfile_amd64_shadow) ship the `main` binary
# separately. A Job spec uses an init container to copy `main` from the
# per-experiment image into an emptyDir, then runs Shadow from this image.
#
# Build via kaniko on a lab worker (Apple Silicon emulation is too slow):
#   kubectl apply -f shadow/kaniko-build-job.yaml
# Pushes to radiken/dst-shadow-base:latest.

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Shadow build/runtime deps (https://shadow.github.io/docs/guide/install_dependencies.html)
# + python3-networkx + python3-yaml for any in-cluster topology generation.
RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake findutils libclang-dev libc-dbg \
    libglib2.0-0 libglib2.0-dev make netbase \
    python3 python3-pip python3-networkx python3-yaml python3-requests xz-utils util-linux \
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

# Bake the pod-api-requester so the Shadow `publisher` host can run it in batch
# mode (`python3 /app/api_requester.py --mode batch --config <mounted>/publisher.yaml`).
# Pinned to a merged commit; bump REQUESTER_REF deliberately.
ARG REQUESTER_REF=e54dbfd19b95bf7d445ba9ce04931d5939591815
RUN git clone https://github.com/vacp2p/pod-api-requester.git /app \
    && git -C /app checkout ${REQUESTER_REF} \
    && rm -rf /app/.git \
    && pip3 install --no-cache-dir --upgrade pip \
    && pip3 install --no-cache-dir -r /app/requirements.txt

# Default working directory for sims; the Job mounts the test-node binary and
# the shadow.yaml here at runtime.
WORKDIR /sim

# No ENTRYPOINT — the Job manifest sets its own command (typically
# `shadow /sim/config/shadow.yaml`) so different experiments can pass
# different invocations without rebuilding the image.
