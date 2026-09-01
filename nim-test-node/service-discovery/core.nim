import std/[sets, sequtils]
import chronos, chronicles, results
import libp2p/protocols/service_discovery
import libp2p/protocols/service_discovery/types
import libp2p/extended_peer_record

proc serviceDataLen(service: ServiceInfo): int =
  when compiles(service.data.len):
    service.data.len
  else:
    if service.data.isSome:
      service.data.get().len
    else:
      0

proc startAdvertisingServices*(
    disco: ServiceDiscovery, services: seq[ServiceInfo]
) =
  if services.len == 0:
    warn "No services configured for advertising"
    return

  for service in services:
    disco.startAdvertising(service).isOkOr:
      warn "Failed to advertise", service = service.id, error = error
      continue
    notice "Advertising service",
      service = service.id,
      dataLen = service.serviceDataLen()

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
