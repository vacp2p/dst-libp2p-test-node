# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import std/sets
import chronos, chronos/unittest2/asynctests, results, chronicles
import lsquic
import ./helpers/certificate

trace "chronicles has to be imported to fix Error: undeclared identifier: 'activeChroniclesStream'"

initializeLsquic(true, true)

type RejectVerifierRecorder = ref object
  rejectCount: int

proc singleAlpn(name: string = "test"): HashSet[string] =
  result = initHashSet[string]()
  result.incl(name)

proc acceptingCertificateCb(
    serverName: string, derCertificates: seq[seq[byte]]
): bool {.gcsafe.} =
  discard serverName
  derCertificates.len > 0

proc rejectingCertificateCb(
    serverName: string, derCertificates: seq[seq[byte]]
): bool {.gcsafe.} =
  discard serverName
  discard derCertificates
  false

proc makeRejectingCertificateCb(
    recorder: RejectVerifierRecorder
): certificateVerifierCB =
  return proc(serverName: string, derCertificates: seq[seq[byte]]): bool {.gcsafe.} =
    discard serverName
    discard derCertificates
    inc recorder.rejectCount
    false

proc makeClientWithVerifier(
    verifier: CertificateVerifier, alpn: HashSet[string] = singleAlpn()
): QuicClient =
  let tlsConfig =
    TLSConfig.new(testCertificate(), testPrivateKey(), alpn, Opt.some(verifier))
  QuicClient.new(tlsConfig)

proc makeServerWithVerifier(
    verifier: CertificateVerifier, alpn: HashSet[string] = singleAlpn()
): QuicServer =
  let tlsConfig =
    TLSConfig.new(testCertificate(), testPrivateKey(), alpn, Opt.some(verifier))
  QuicServer.new(tlsConfig)

suite "certificate verifier":
  teardown:
    cleanupLsquic()

  asyncTest "accepting custom verifier allows handshake":
    let client =
      makeClientWithVerifier(CustomCertificateVerifier.init(acceptingCertificateCb))
    let server =
      makeServerWithVerifier(CustomCertificateVerifier.init(acceptingCertificateCb))
    let listener = server.listen(initTAddress("127.0.0.1:0"))
    defer:
      await allFutures(client.stop(), listener.stop())

    let accepting = listener.accept()
    let outgoing = await client.dial(listener.localAddress())
    let incoming = await accepting

    check:
      outgoing.certificates().len == 1
      incoming.certificates().len == 1

    outgoing.close()
    incoming.close()

  asyncTest "rejecting client verifier rejects handshake":
    let client =
      makeClientWithVerifier(CustomCertificateVerifier.init(rejectingCertificateCb))
    let server =
      makeServerWithVerifier(CustomCertificateVerifier.init(acceptingCertificateCb))
    let listener = server.listen(initTAddress("127.0.0.1:0"))
    defer:
      await allFutures(client.stop(), listener.stop())

    expect DialError:
      discard await client.dial(listener.localAddress())

  asyncTest "alpn mismatch rejects handshake":
    let client = makeClientWithVerifier(
      CustomCertificateVerifier.init(acceptingCertificateCb), singleAlpn("client-proto")
    )
    let server = makeServerWithVerifier(
      CustomCertificateVerifier.init(acceptingCertificateCb), singleAlpn("server-proto")
    )
    let listener = server.listen(initTAddress("127.0.0.1:0"))
    defer:
      await allFutures(client.stop(), listener.stop())

    expect DialError:
      discard await client.dial(listener.localAddress())

  asyncTest "server-side verifier callback does not fail handshake without client auth":
    let recorder = RejectVerifierRecorder()
    let client =
      makeClientWithVerifier(CustomCertificateVerifier.init(acceptingCertificateCb))
    let server = makeServerWithVerifier(
      CustomCertificateVerifier.init(recorder.makeRejectingCertificateCb())
    )
    let listener = server.listen(initTAddress("127.0.0.1:0"))
    defer:
      await allFutures(client.stop(), listener.stop())

    let outgoing = await client.dial(listener.localAddress())
    await sleepAsync(100.milliseconds)

    check:
      outgoing.certificates().len == 1
      recorder.rejectCount == 1

    outgoing.close()

  asyncTest "insecure verifier allows handshake":
    let client = makeClientWithVerifier(InsecureCertificateVerifier.init())
    let server =
      makeServerWithVerifier(CustomCertificateVerifier.init(acceptingCertificateCb))
    let listener = server.listen(initTAddress("127.0.0.1:0"))
    defer:
      await allFutures(client.stop(), listener.stop())

    let accepting = listener.accept()
    let outgoing = await client.dial(listener.localAddress())
    let incoming = await accepting

    check:
      outgoing.certificates().len == 1
      incoming.certificates().len == 1

    outgoing.close()
    incoming.close()
