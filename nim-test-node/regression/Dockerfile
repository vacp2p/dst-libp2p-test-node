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

# fix #1837: honor locked package URLs during installation (#1838)
RUN nimble install -y 'nimble@#07caee397d628c9e93d81048268365c4c2414a80'
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
