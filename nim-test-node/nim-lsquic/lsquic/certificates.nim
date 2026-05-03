# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import results
import ./lsquic_ffi
import ./helpers/sequninit

proc x509toDERBytes*(cert: ptr X509): Opt[seq[byte]] =
  if cert.isNil:
    return Opt.none(seq[byte])

  let derBuf: ptr uint8 = nil
  let derLen = i2d_X509(cert, addr derBuf)
  defer:
    if derBuf != nil:
      OPENSSL_free(derBuf)

  if derLen > 0:
    let outp = newSeqUninit[byte](derLen)
    copyMem(addr outp[0], derBuf, derLen)
    return Opt.some(outp)
  return Opt.none(seq[byte])

proc getCertChain*(chain: ptr struct_stack_st_X509): seq[seq[byte]] =
  var output: seq[seq[byte]] = @[]

  if chain.isNil:
    return output

  let x509num = OPENSSL_sk_num(cast[ptr OPENSSL_STACK](chain))
  for i in 0 ..< x509num:
    let chainC = OPENSSL_sk_value(cast[ptr OPENSSL_STACK](chain), csize_t(i))
    let certBytes = x509toDERBytes(cast[ptr X509](chainC))
    if certBytes.isSome:
      output.add(certBytes.value())

  return output

proc getFullCertChain*(ssl: ptr SSL): seq[seq[byte]] =
  SSL_get_peer_full_cert_chain(ssl).getCertChain()
