FROM rust:1.91.0 as builder

WORKDIR /node

COPY Cargo.* ./

COPY src ./src

RUN cargo build --release


FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /node

# Copy the binary from builder
COPY --from=builder /node/target/release/rust-test-node /node/main

RUN chmod +x main

# Expose ports
EXPOSE 5000 8008 8645

ENTRYPOINT ["./main"]