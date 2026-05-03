# nim-lsquic

[![Tests](https://github.com/vacp2p/nim-lsquic/actions/workflows/test.yml/badge.svg)](https://github.com/vacp2p/nim-lsquic/actions/workflows/test.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE-APACHEv2)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE-MIT)

`nim-lsquic` is a Nim wrapper around [`lsquic`](https://github.com/litespeedtech/lsquic) with a Chronos-based async API for QUIC clients, servers, connections, and streams.

The repository vendors `lsquic` and `boringssl` as submodules and exposes a higher-level Nim interface on top of the generated FFI bindings. The current public API is focused on transport primitives: runtime setup, TLS configuration, dialing, listening, connection lifecycle, and bidirectional QUIC streams.

## Background

[`lsquic`](https://github.com/litespeedtech/lsquic) is a mature QUIC and HTTP/3 implementation in C. This project wraps the QUIC pieces in a more Nim-friendly API built around [Chronos](https://github.com/status-im/nim-chronos).

If you want to open QUIC connections and exchange stream data from Nim without writing directly against the C interface, this repository is the layer for that. It is not a full HTTP/3 framework at the moment; the public API is centered on QUIC transport functionality.

## Features

- Async `QuicClient` and `QuicServer` types built on Chronos futures
- `Listener`, `Connection`, and `Stream` abstractions over the underlying `lsquic` engine
- TLS setup via `TLSConfig`
- Pluggable certificate verification with `CustomCertificateVerifier` or `InsecureCertificateVerifier`
- Generated low-level bindings in [`lsquic/lsquic_ffi.nim`](lsquic/lsquic_ffi.nim)
- CI coverage on Linux, macOS, and Windows across Nim 2.0 and 2.2

## Install

For development or local use, clone the repository with submodules and install the Nim dependencies:

```bash
git clone --recursive https://github.com/vacp2p/nim-lsquic.git
cd nim-lsquic
nimble install
```

### Requirements

- Nim `>= 2.0.0`
- A working C/C++ toolchain
- `zlib`
- On Windows, a Clang-compatible toolchain and `nasm` are required in CI

The project links through a C++ linker profile on non-Windows platforms, so `g++` or `clang++` must be available.

## Quick Start

The main entry point is [`lsquic.nim`](lsquic.nim):

```nim
import std/[sequtils, sets]
import chronos
import results
import lsquic

proc toBytes(s: string): seq[byte] =
  toSeq(s.toOpenArrayByte(0, s.high))

proc readAll(stream: Stream): Future[seq[byte]] {.async.} =
  var buf = newSeq[byte](1024)
  while true:
    let n = await stream.readOnce(buf)
    if n == 0:
      break
    result.add(buf[0 ..< n])

const
  certPem = staticRead("cert.pem")
  keyPem = staticRead("key.pem")

proc main() {.async.} =
  initializeLsquic()
  defer:
    cleanupLsquic()

  let alpn = ["echo"].toHashSet()

  let server = QuicServer.new(
    TLSConfig.new(
      certificate = toBytes(certPem),
      key = toBytes(keyPem),
      alpn = alpn,
    )
  )

  let devVerifier: CertificateVerifier = InsecureCertificateVerifier.init()
  let client = QuicClient.new(
    TLSConfig.new(
      certificate = toBytes(certPem),
      key = toBytes(keyPem),
      alpn = alpn,
      certVerifier = Opt.some(devVerifier),
    )
  )

  let listener = server.listen(initTAddress("127.0.0.1:0"))
  defer:
    await allFutures(client.stop(), listener.stop())

  let accepting = listener.accept()
  let clientConn = await client.dial(listener.localAddress())
  let serverConn = await accepting

  let serverTask = proc() {.async.} =
    let stream = await serverConn.incomingStream()
    let request = await stream.readAll()
    await stream.write(request)
    await stream.close()
    serverConn.close()

  asyncSpawn serverTask()

  let stream = await clientConn.openStream()
  let message = @['p'.byte, 'i'.byte, 'n'.byte, 'g'.byte]
  await stream.write(message)
  await stream.close()

  let reply = await stream.readAll()
  doAssert reply == message

  clientConn.close()

waitFor main()
```

The snippet expects `cert.pem` and `key.pem` in PEM format and embeds them at compile time with `staticRead`. It also reuses the same certificate material on both sides purely to keep the example short.

`InsecureCertificateVerifier` is only appropriate for local development and tests. In real deployments, use `CustomCertificateVerifier` or another verifier that checks the peer certificate chain according to your trust model.

### Usage Notes

- Call `initializeLsquic()` before creating clients or servers.
- `cleanupLsquic()` is idempotent and can be safely called during shutdown.
- Server-side `TLSConfig` must include both a certificate and a private key.
- Client and server ALPN values must match or the handshake will fail.
- `Connection.close()` and `Stream.close()` perform a graceful shutdown. `abort()` is the hard-stop path.

For more complete usage patterns, see:

- [`tests/test_connection.nim`](tests/test_connection.nim)
- [`tests/test_lifecycle.nim`](tests/test_lifecycle.nim)
- [`tests/test_verifier.nim`](tests/test_verifier.nim)
- [`tests/test_stress.nim`](tests/test_stress.nim)

## Development

### Run tests

```bash
nimble test
nimble test_release
```

The CI matrix exercises:

- Linux amd64 and i386
- Linux with GCC 14
- macOS arm64
- Windows amd64
- Nim 2.0 (`refc`) and Nim 2.2 (`refc` and `orc`)

### Format

```bash
nimble format
```

### Regenerate the FFI bindings

If the vendored `lsquic` or BoringSSL headers change, regenerate [`lsquic/lsquic_ffi.nim`](lsquic/lsquic_ffi.nim):

```bash
./build.sh
```

The script installs `futhark@0.15.0`, regenerates the binding file, and appends the project-specific prelude and extras.


## Modules

| Module | Description |
| --- | --- |
| [`lsquic`](lsquic.nim) | Top-level import that re-exports the main public API |
| [`lsquic/lsquic`](lsquic/lsquic.nim) | Process-wide `lsquic` initialization and cleanup |
| [`lsquic/client`](lsquic/client.nim) | `QuicClient` creation, dialing, and transport shutdown |
| [`lsquic/server`](lsquic/server.nim) | `QuicServer`, `Listener`, binding, and `accept()` |
| [`lsquic/connection`](lsquic/connection.nim) | Connection lifecycle, stream creation, certificate access |
| [`lsquic/stream`](lsquic/stream.nim) | Async stream reads, writes, close, and abort |
| [`lsquic/tlsconfig`](lsquic/tlsconfig.nim) | TLS configuration plus PEM-to-X509/PKey helpers |
| [`lsquic/certificateverifier`](lsquic/certificateverifier.nim) | Base, custom, and insecure certificate verifier adapters |
| [`lsquic/lsquic_ffi`](lsquic/lsquic_ffi.nim) | Generated low-level bindings to the vendored native libraries |

## License

Licensed and distributed under either of

- MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT

or

- Apache License, Version 2.0, ([LICENSE-APACHEv2](LICENSE-APACHEv2) or http://www.apache.org/licenses/LICENSE-2.0)

at your option. These files may not be copied, modified, or distributed except according to those terms.
