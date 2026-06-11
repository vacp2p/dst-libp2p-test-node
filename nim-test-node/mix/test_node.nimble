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
          "https://github.com/vacp2p/nim-libp2p#c43199378f46d0aaf61be1cad1ee1d63e8f665d6", # release/v2.0.0 tip
          "https://github.com/logos-co/nim-libp2p-mix#380513117d556bf8f70066f5e72a7fd74fe36ba6" # head as of 2026-06-09