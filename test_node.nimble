mode = ScriptMode.Verbose

bin = @["main"]

packageName   = "test_node"
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "A test node for gossipsub"
license       = "MIT"
skipDirs      = @[]

requires "nim >= 2.2.6",
          # "https://github.com/PearsonWhite/nim-libp2p#20d6c634e3b608d7f6d7d09fbc0b0f70670b1d90", 1.14.0
          "https://github.com/vacp2p/nim-libp2p#35ecbb14394454d94c4683420cbf80a249dc5d3e", # 1.16.0
          "chronicles >= 0.12.2", "chronos >= 4.0.4", "metrics", "secp256k1",
          "nimcrypto >= 0.6.0", "dnsclient >= 0.3.0 & < 0.4.0", "bearssl >= 0.2.5",
          "stew >= 0.4.2", "websock >= 0.2.1", "unittest2", "results", "quic >= 0.3.0",
          "https://github.com/vacp2p/nim-jwt.git#18f8378de52b241f321c1f9ea905456e89b95c6f",
          "ggplotnim"