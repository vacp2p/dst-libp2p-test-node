FROM nimlang/nim:2.2.10 AS build

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      build-essential \
      xz-utils \
      libssl-dev && \
    rm -rf /var/lib/apt/lists/*

# fix #1837: honor locked package URLs during installation (#1838)
RUN nimble install -y 'nimble@#07caee397d628c9e93d81048268365c4c2414a80'
ENV PATH="/root/.nimble/bin:${PATH}"

WORKDIR /node
COPY test_node.nimble .

RUN nimble install -dy

COPY *.nim .

RUN nimble c \
    -d:chronicles_colors=None --threads:on --mm:refc \
    -d:metrics -d:libp2p_network_protocols_metrics -d:release \
    --passL:"-static-libgcc -static-libstdc++" \
    -d:chronicles_log_level=INFO \
    --out:/node/main \
    main

FROM debian:bookworm-slim

RUN apt-get update && \
 apt-get install -y --no-install-recommends \
   ca-certificates \
   libssl3 \
   iproute2 \
   curl \
   procps && \
 rm -rf /var/lib/apt/lists/* && \
 apt-get clean

WORKDIR /node

COPY --from=build /node/main /node/main

RUN chmod +x /node/main

EXPOSE 5000 8645

ENTRYPOINT ["./main"]
