#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="soutullostatus/service-discovery:v2.1.0"
NETWORK_NAME="service-discovery-network"

echo "Cleaning previous environment..."
docker rm -f sd-bootstrap sd-advertiser sd-discoverer 2>/dev/null || true
docker network rm "${NETWORK_NAME}" 2>/dev/null || true

echo "Building image..."
docker build -t "${IMAGE_NAME}" "${SCRIPT_DIR}"

echo "Creating network..."
docker network create "${NETWORK_NAME}"

echo "Starting bootstrap..."
docker run -d \
  --name sd-bootstrap \
  --network "${NETWORK_NAME}" \
  -e NODE_ROLE=RoleBootstrap \
  "${IMAGE_NAME}"

sleep 2

echo "Starting advertiser..."
docker run -d \
  --name sd-advertiser \
  --network "${NETWORK_NAME}" \
  -e NODE_ROLE=RoleAdvertiser \
  -e SERVICE=sd-bootstrap \
  -e ADVERTISE_SERVICES=chat \
  -e SERVICE_DATA=status \
  "${IMAGE_NAME}"

echo "Starting discoverer..."
docker run -d \
  --name sd-discoverer \
  --network "${NETWORK_NAME}" \
  -e NODE_ROLE=RoleDiscoverer \
  -e SERVICE=sd-bootstrap \
  -e DISCOVER_SERVICES=chat \
  -e LOOKUP_INTERVAL_SECONDS=10 \
  -e SD_CLIENT=true \
  "${IMAGE_NAME}"

echo "Done."
echo "Bootstrap logs:  docker logs -f sd-bootstrap"
echo "Advertiser logs: docker logs -f sd-advertiser"
echo "Discoverer logs: docker logs -f sd-discoverer"
