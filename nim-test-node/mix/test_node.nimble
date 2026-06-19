mode = ScriptMode.Verbose

bin = @["main"]

packageName   = "test_node"
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "A nim-libp2p test node with mix protocol support"
license       = "MIT"
skipDirs      = @[]

requires "nim >= 2.2.4",
          "nimcrypto 0.6.4",
          "libp2p 2.0.0",
          "https://github.com/logos-co/nim-libp2p-mix#03d9139" # PR fix for enable_mix_benchmarks; head as of 2026-06-19