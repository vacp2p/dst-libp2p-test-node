# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

type
  StreamResetHow* {.pure.} = enum
    ResetRead = 0
    ResetWrite = 1
    ResetReadWrite = 2

  QuicError* = object of CatchableError
  QuicConfigError* = object of QuicError
  StreamError* = object of IOError
  StreamResetError* = object of StreamError
    how*: StreamResetHow

  ConnectionError* = object of IOError
  ConnectionClosedError* = object of ConnectionError
  DialError* = object of IOError
