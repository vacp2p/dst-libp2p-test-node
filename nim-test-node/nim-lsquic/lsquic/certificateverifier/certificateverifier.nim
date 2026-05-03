# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

type CertificateVerifier* = ref object of RootObj

method verify*(
    self: CertificateVerifier, serverName: string, derCertificates: seq[seq[byte]]
): bool {.base.} =
  raiseAssert "override method: verify"
