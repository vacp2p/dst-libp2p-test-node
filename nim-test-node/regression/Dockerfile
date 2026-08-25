FROM nimlang/nim:latest

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

RUN git config --global http.sslVerify false

COPY test_node.nimble .
RUN nimble refresh && nimble install -dy

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
