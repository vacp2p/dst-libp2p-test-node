import libp2p/peerid

proc randomPeerId*[R](rng: R): PeerId =
  ## Generate a random peer ID using the caller's random number generator.
  PeerId.random(rng).get()

proc randomPeerIds*[R](rng: R, count: Natural): seq[PeerId] =
  ## Generate `count` random peer IDs using the same random number generator.
  PeerId.random(count.uint, rng).get()
