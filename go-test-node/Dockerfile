# Create the build image
FROM golang:1.25.3-bookworm AS build

# Copy files to working directory, download dependencies for better caching
WORKDIR /node
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN go build -o main .

FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
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