FROM debian:bookworm-slim AS build

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    build-essential \
    xz-utils \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl https://nim-lang.org/choosenim/init.sh -sSf | sh -s -- -y
ENV PATH="/root/.nimble/bin:${PATH}"

WORKDIR /node
COPY . .

RUN git config --global http.sslVerify false

RUN nimble install -dy

RUN nimble c \
    -d:chronicles_colors=None --threads:on --mm:refc \
    -d:metrics -d:libp2p_network_protocols_metrics -d:release \
    --passL:"-static-libgcc -static-libstdc++" \
    main

FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    libssl3 \
    iproute2 \
    curl \
    procps \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

WORKDIR /node

COPY --from=build /node/main /node/main

RUN chmod +x main

EXPOSE 5000 8008 8645

ENTRYPOINT ["./main"]