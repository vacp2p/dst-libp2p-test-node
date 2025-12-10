import os, strutils, sequtils, std/strformat
import chronos
import env
from nativesockets import getHostname
import libp2p, libp2p/[muxers/mplex/lpchannel, crypto/secp, multiaddress, peerid]
import libp2p/protocols/[pubsub/pubsubpeer, pubsub/rpc/messages, ping]
import libp2p/protocols/[mix/mix_node, mix/entry_connection, mix/mix_protocol]

var mixNodes: MixNodes

proc mixPeerSelection*(
    allPeers: HashSet[PubSubPeer],
    directPeers: HashSet[PubSubPeer],
    meshPeers: HashSet[PubSubPeer],
    fanoutPeers: HashSet[PubSubPeer],
): HashSet[PubSubPeer] {.gcsafe, raises: [].} =
  var
    peers: HashSet[PubSubPeer]
    allPeersSeq = allPeers.toSeq()
  let rng = newRng()
  rng.shuffle(allPeersSeq)
  for p in allPeersSeq:
    peers.incl(p)
    if peers.len >= mix_D:
      break
  return peers

#mix custom peer selection callback
proc makeMixPeerSelectCb*(): CustomPeerSelectionProc =
  return proc(
    allPeers: HashSet[PubSubPeer],
    directPeers: HashSet[PubSubPeer],
    meshPeers: HashSet[PubSubPeer],
    fanoutPeers: HashSet[PubSubPeer],
  ): HashSet[PubSubPeer] {.gcsafe, raises: [].} =
    try:
      return mixPeerSelection(allPeers, directPeers, meshPeers, fanoutPeers)
    except CatchableError as e:
      error "Error during execution of MixPeerSelection callback", err = e.msg
      return initHashSet[PubSubPeer]()

#mix custom connection callback
proc makeMixConnCb*(mixProto: MixProtocol): CustomConnCreationProc =
  return proc(
      destAddr: Option[MultiAddress], destPeerId: PeerId, codec: string
  ): Connection {.gcsafe, raises: [].} =
    try:
      let dest = destAddr.valueOr:
        error "No destination address available for MixEntryConnection", destPeer = destPeerId
        return nil
      
      info "Creating mix connection", destPeerId = destPeerId, destAddr = dest

      let params = MixParameters(
        expectReply: Opt.some(false),
        numSurbs: Opt.some(0'u8)
      )
      let connResult = mixProto.toConnection(
        MixDestination.init(destPeerId, dest), 
        codec,
        params
      ).valueOr:
        error "Failed to create mix connection"
        return nil

      info "Mix connection created successfully", destPeerId = destPeerId
      return connResult

    except CatchableError as e:
      error "Error during execution of MixEntryConnection callback: ", err = e.msg
      return nil

proc initializeMix*(myId: int): 
  Result[(MultiAddress, SkPublicKey, SkPrivateKey), string] =
  {.gcsafe.}:
    if mountsMix:
      mixNodes = initializeMixNodes(1, int(myPort)).valueOr:
        return err("Could not generate Mix nodes: " & error)

      let (peerId, multiAddr, mixPubKey, mixPrivKey, libp2pPubKey, libp2pPrivKey) = mixNodes[0].get()
      ok((multiAddr, libp2pPubKey, libp2pPrivKey))
    else:
      let
        rng = newRng()
        keyPair = SkKeyPair.random(rng[])
        pubKeyProto = PublicKey(scheme: Secp256k1, skkey: keyPair.pubkey)
        peerId = PeerId.init(pubKeyProto).get()
        multiAddr = MultiAddress.init(
          #fmt"/ip4/0.0.0.0/tcp/{myPort}/p2p/{peerId}"
          fmt"/ip4/0.0.0.0/tcp/{myPort}"
        ).valueOr:
          return err("Failed to create multiaddress")

      ok((multiAddr, keyPair.pubkey, keyPair.seckey))

proc writeMixInfoFiles*(switch: Switch, myId: int, publicKey: SkPublicKey, filePath: string) =
  {.gcsafe.}:
    var externalAddr: string = ""
    let addresses = getInterfaces().filterIt(it.name == "eth0").mapIt(it.addresses)

    if addresses.len < 1 or addresses[0].len < 1:
      if inShadow and fileExists("/etc/hosts"):
        let
          content = readFile("/etc/hosts")
          hostname = gethostname()
        for line in content.splitLines():
          if line.contains(hostname) and not line.startsWith("#"):
            let
              parts = line.strip().split()
              ip = parts[0]
            if not (ip.startsWith("127") or ip.contains("::1")):
                externalAddr = ip
                break
    else:        
      externalAddr = ($addresses[0][0].host).split(":")[0]
    
    if externalAddr == "":
      info "Can't find external IP address", peer = myId
      return

    let
      peerId = switch.peerInfo.peerId
      externalMultiAddr = MultiAddress.init(
        fmt"/ip4/{externalAddr}/tcp/{myPort}"
      ).valueOr:
        error "Failed to create external multiaddress", err = error
        return

    if mountsMix:
      discard mixNodes.initMixMultiAddrByIndex(0, peerId, externalMultiAddr)

      mixNodes[0].writeToFile(myId, filePath / "nodeInfo").isOkOr:
        error "Failed to write mix node info to file", nodeId = myId, err = error
        return

      let nodePubInfo = mixNodes.getMixPubInfoByIndex(0).valueOr:
        error "Get mix pub info by index error", nodeId = myId, err = error
        return

      nodePubInfo.writeToFile(myId, filePath / "pubInfo").isOkOr:
        error "Failed to write mix pub info to file", nodeId = myId, err = error
        return

    info "Successfully written mix info", peer = myId, address = externalMultiAddr
