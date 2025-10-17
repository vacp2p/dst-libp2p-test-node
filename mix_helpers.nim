import os, strutils, sequtils, std/strformat
import chronos
import node, env
from nativesockets import getHostname

import mix/[mix_node, entry_connection, mix_protocol]
import libp2p, libp2p/[muxers/mplex/lpchannel, crypto/secp, multiaddress, peerid]
import libp2p/protocols/[pubsub/pubsubpeer, pubsub/rpc/messages, ping]

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
      return mixProto.toConnection(MixDestination.init(destPeerId, dest), codec).get()
    except CatchableError as e:
      error "Error during execution of MixEntryConnection callback: ", err = e.msg
      return nil

proc initializeMix*(myId: int): 
  Result[(MultiAddress, SkPublicKey, SkPrivateKey), string] =
  {.gcsafe.}:
    let (multiAddrStr, libp2pPubKey, libp2pPrivKey) =
      if mountsMix:
        mixNodes = initializeMixNodes(1, int(myPort)).valueOr:
          return err("Could not generate Mix nodes")
        let (ma, _, _, pubKey, privKey) = getMixNodeInfo(mixNodes[0])
        (ma, pubKey, privKey)  
      else:
        discard initializeNodes(1, int(myPort))
        getNodeInfo(nodes[0])
    
    let 
      multiAddrParts = multiAddrStr.split("/p2p/")
      multiAddr = MultiAddress.init(multiAddrParts[0]).valueOr:
        return err("Failed to initialize MultiAddress for Mix")
    
    ok((multiAddr, libp2pPubKey, libp2pPrivKey))


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
      externalMultiAddr = fmt"/ip4/{externalAddr}/tcp/{myPort}/p2p/{peerId}"

    if mountsMix:
      discard mixNodes.initMixMultiAddrByIndex(0, externalMultiAddr)
      writeMixNodeInfoToFile(mixNodes[0], myId, filePath / fmt"nodeInfo").isOkOr:
        error "Failed to write mix info to file", nodeId = myId, err = error
        return

      let nodePubInfo = mixNodes.getMixPubInfoByIndex(0).valueOr:
        error "Get mix pub info by index error", nodeId = myId, err = error
        return
      writeMixPubInfoToFile(nodePubInfo, myId, filePath / fmt"pubInfo").isOkOr:
        error "Failed to write mix pub info to file", nodeId = myId, err = error
        return
    let pubInfo = initPubInfo(externalMultiAddr, publicKey)
    writePubInfoToFile(pubInfo, myId, filePath / fmt"libp2pPubInfo").isOkOr:
      error "Failed to write pub info to file", nodeId = myId, err = error
      return

    info "Successfully written mix info", peer = myId, address = externalMultiAddr

