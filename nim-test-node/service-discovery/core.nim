import std/[sets, sequtils]
import chronos, chronicles
import libp2p/protocols/service_discovery
import libp2p/protocols/service_discovery/types
import libp2p/extended_peer_record

proc startAdvertisingServices*(
    disco: ServiceDiscovery, services: seq[ServiceInfo]
) =
  if services.len == 0:
    warn "No services configured for advertising"
    return

  for service in services:
    disco.startAdvertising(service)
    notice "Advertising service",
      service = service.id,
      dataLen = service.data.len

proc startDiscoveringServicesLog*(
    disco: ServiceDiscovery, serviceIds: seq[string]
) =
  if serviceIds.len == 0:
    warn "No services configured for discovery"
    return

  for serviceId in serviceIds:
    notice "Discovering service", service = serviceId

proc runLookupLoop*(
    disco: ServiceDiscovery, serviceIds: seq[string], lookupInterval: Duration
) {.async.} =
  while true:
    for serviceId in serviceIds:
      let lookupRes = await disco.lookup(serviceId.hashServiceId())
      let ads = lookupRes.valueOr:
        warn "Lookup failed", service = serviceId, error
        continue

      var uniquePeers = initHashSet[string]()
      for ad in ads:
        uniquePeers.incl($ad.data.peerId)
        debug "Advertisement found",
          service = serviceId,
          peerId = $ad.data.peerId,
          seqNo = ad.data.seqNo,
          addrs = ad.data.addresses.mapIt($it.address)

      notice "Lookup completed",
        service = serviceId,
        advertisements = ads.len,
        uniquePeers = uniquePeers.len

    await sleepAsync(lookupInterval)
