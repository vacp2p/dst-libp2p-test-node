FROM nimlang/nim:2.2.10

WORKDIR /node

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    ca-certificates \
    curl \
    libssl3 \
    iproute2 \
    procps \
    && rm -rf /var/lib/apt/lists/*

RUN git config --global http.version HTTP/1.1

RUN nimble install -y 'nimble@#b1b0690e5028244c04f7bb8daafb5d9e37d31b62'
ENV PATH="/root/.nimble/bin:${PATH}"

COPY test_node.nimble nimble.lock config.nims ./
RUN nimble refresh && nimble setup

COPY . .

ARG NODE_BINARY=node
RUN test "${NODE_BINARY}" = "node" -o "${NODE_BINARY}" = "bootstrap"
RUN nimble c \
    -d:chronicles_colors=None --threads:on --mm:refc \
    -d:metrics -d:libp2p_network_protocols_metrics -d:release \
    --out:/node/main \
    "${NODE_BINARY}/main.nim"

EXPOSE 5000 8008 8645

ENTRYPOINT ["/node/main"]
