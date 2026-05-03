# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import std/sets
import results
import ./[errors, certificateverifier, lsquic_ffi]

type TLSConfig* = ref object
  certVerifier*: Opt[CertificateVerifier]
  certificate*: seq[byte]
  key*: seq[byte]
  alpnWire*: string

proc new*(
    T: typedesc[TLSConfig],
    certificate: seq[byte] = @[],
    key: seq[byte] = @[],
    alpn: HashSet[string] = initHashSet[string](),
    certVerifier: Opt[CertificateVerifier] = Opt.none(CertificateVerifier),
): T =
  # In a config, certificate and keys are optional, but if using them, both must
  # be specified at the same time
  if certificate.len != 0 or key.len != 0:
    if certificate.len == 0:
      raise newException(QuicConfigError, "certificate is required in TLSConfig")

    if key.len == 0:
      raise newException(QuicConfigError, "key is required in TLSConfig")

  var alpnWire = newString(0)
  for a in alpn:
    alpnWire.add chr(a.len)
    alpnWire.add a

  TLSConfig(
    alpnWire: alpnWire, certVerifier: certVerifier, certificate: certificate, key: key
  )

proc toX509*(pemCertificate: seq[byte]): Result[ptr X509, string] =
  if pemCertificate.len == 0:
    return err("certificate is empty")

  let bio = BIO_new_mem_buf(addr pemCertificate[0], ossl_ssize_t(pemCertificate.len))
  if bio.isNil:
    return err("could not create x509 bio")

  let x509 = PEM_read_bio_X509(bio, nil, nil, nil)
  if BIO_free(bio) != 1:
    if not x509.isNil:
      X509_free(x509)
    return err("could not free x509 bio")
  if x509.isNil:
    return err("could not parse x509 certificate")
  ok(x509)

proc toPKey*(pemKey: seq[byte]): Result[ptr EVP_PKEY, string] =
  if pemKey.len == 0:
    return err("key is empty")

  let bio = BIO_new_mem_buf(addr pemKey[0], ossl_ssize_t(pemKey.len))
  if bio.isNil:
    return err("could not create pkey bio")

  let p = PEM_read_bio_PrivateKey(bio, nil, nil, nil)
  if BIO_free(bio) != 1:
    if not p.isNil:
      EVP_PKEY_free(p)
    return err("could not free pkey bio")
  if p.isNil:
    return err("could not parse private key")
  ok(p)
