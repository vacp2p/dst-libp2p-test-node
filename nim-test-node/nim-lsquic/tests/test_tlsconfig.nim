# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import std/sets
import results
import unittest2
import lsquic
import lsquic/certificates
import lsquic/lsquic_ffi
import ./helpers/certificate

proc singleAlpn(): HashSet[string] =
  result = initHashSet[string]()
  result.incl("test")

suite "tls config":
  test "certificate requires key":
    expect QuicConfigError:
      discard TLSConfig.new(certificate = testCertificate())

  test "key requires certificate":
    expect QuicConfigError:
      discard TLSConfig.new(key = testPrivateKey())

  test "server requires certificate":
    expect QuicConfigError:
      discard QuicServer.new(TLSConfig.new())

  test "single alpn value is encoded":
    let cfg = TLSConfig.new(testCertificate(), testPrivateKey(), singleAlpn())

    check cfg.alpnWire == "\x04test"

  test "valid pem certificate parses":
    let parsed = testCertificate().toX509()

    check parsed.isOk()
    let cert = parsed.valueOr:
      nil
    check not cert.isNil
    if not cert.isNil:
      check cert.x509toDERBytes().isSome()
    if not cert.isNil:
      X509_free(cert)

  test "nil x509 DER conversion is rejected":
    let cert: ptr X509 = nil

    check cert.x509toDERBytes().isNone()

  test "valid pem key parses":
    let parsed = testPrivateKey().toPKey()

    check parsed.isOk()
    let pkey = parsed.valueOr:
      nil
    check not pkey.isNil
    if not pkey.isNil:
      EVP_PKEY_free(pkey)

  test "empty pem values are rejected":
    check @[].toX509().isErr()
    check @[].toPKey().isErr()

  test "invalid pem values are rejected":
    let invalidPem =
      @['n'.byte, 'o'.byte, 't'.byte, ' '.byte, 'p'.byte, 'e'.byte, 'm'.byte]

    check invalidPem.toX509().isErr()
    check invalidPem.toPKey().isErr()
