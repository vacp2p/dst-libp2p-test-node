mode = ScriptMode.Verbose

bin = @["main"]

packageName   = "test_node"
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "A test node for gossipsub"
license       = "MIT"
skipDirs      = @[]

requires "nim >= 2.2.0",
          "nimcrypto 0.6.4",
          "https://github.com/vacp2p/nim-libp2p#d721f9cb13c36b844957556ac04fecade371b059", # release/v2.2.0
          # Hold lsquic at 0.5.4: the version v2.2.0 and v2.1.0 were built and tested
          # against (0.5.5/0.5.6 were tagged after the cluster runs). Keeps the shadow
          # quic stack matching the cluster and lets the tick-floor patch apply.
          # URL-pinned to the tag so nimble can't greedily resolve a newer lsquic.
          "https://github.com/vacp2p/nim-lsquic#v0.5.4",
          "ggplotnim"