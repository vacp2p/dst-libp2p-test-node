#!/bin/bash
# Spin up a local test mixnet of arbitrary size.
#
#   ./mixnet.sh up [N=5]
#   ./mixnet.sh logs [pod=pod-0]
#   ./mixnet.sh down
#   ./mixnet.sh smoke         # spin up N=5, verify mix-ping flows across pods

set -e

IMAGE=${IMAGE:-dst-test-node-mix:wip}
NETWORK=${NETWORK:-mixnet}
PUBINFOS=${PUBINFOS:-/tmp/mixnet-pubinfos}

# Clean up pods on Ctrl-C so the next invocation isn't blocked by stale containers.
trap 'docker ps -a --filter "name=^pod-" -q | xargs -r docker rm -f >/dev/null 2>&1 || true' INT TERM

cmd_up() {
  local N=${1:-5}

  docker network create "$NETWORK" 2>/dev/null || true
  mkdir -p "$PUBINFOS"

  # Launch in parallel so all containers boot at roughly the same time
  # instead of being staggered by a sequential loop. Image's ENV FILEPATH=/data
  # sets the pubInfo dir; only the host volume needs binding here.
  for i in $(seq 0 $((N - 1))); do
    docker run -d \
      --name "pod-$i" --hostname "pod-$i" --network "$NETWORK" \
      -v "$PUBINFOS":/data \
      -e PEERS="$N" \
      -e NUMMIX="$N" \
      -e CONNECTTO=3 \
      -e LOCALSMOKE=true \
      -e MUXER=yamux \
      -e MAXCONNECTIONS=20 \
      -e STARTSLEEP=15 \
      --platform linux/amd64 \
      "$IMAGE" > /dev/null &
  done
  wait

  echo "Mixnet ready: $N nodes"
  echo "  logs:  ./mixnet.sh logs pod-0"
  echo "  down:  ./mixnet.sh down"
}

cmd_logs() {
  local POD=${1:-pod-0}
  docker logs -f "$POD"
}

cmd_down() {
  docker ps -a --filter "name=^pod-" -q | xargs -r docker rm -f > /dev/null
  docker network rm "$NETWORK" 2>/dev/null || true
  rm -rf "$PUBINFOS"
  echo "Mixnet stopped"
}

_count_log_match() {
  # Count pods (pod-0 .. pod-$((N-1))) whose docker logs contain $2.
  local N=$1; local PATTERN=$2; local C=0
  for i in $(seq 0 $((N - 1))); do
    docker logs "pod-$i" 2>&1 | grep -q "$PATTERN" && C=$((C + 1))
  done
  echo "$C"
}

cmd_smoke() {
  echo "=== Smoke test: spin up N=5 and verify mix-ping flows ==="
  # N=5 satisfies env.nim validation NUMMIX >= PathLength + 2 for the current
  # libp2p-mix pin (PathLength=3). If a pin bump raises PathLength, raise N too.
  local N=5
  cmd_down >/dev/null 2>&1 || true
  cmd_up $N >/dev/null
  echo "  warmup 90s..."
  sleep 90
  local P=$(_count_log_match $N "mix-ping ok")
  cmd_down >/dev/null
  if [ "$P" -ge 1 ]; then
    echo "  ok: $P/$N pods logged mix-ping ok"
    echo "=== Smoke PASS ==="
    return 0
  else
    echo "  FAIL: no pod logged mix-ping ok"
    echo "=== Smoke FAIL ==="
    return 1
  fi
}

case "$1" in
  up)    shift; cmd_up "$@" ;;
  logs)  shift; cmd_logs "$@" ;;
  down)  cmd_down ;;
  smoke) cmd_smoke ;;
  *)
    echo "Usage: $0 {up [N]|logs [pod]|down|smoke}"
    echo "  defaults: N=5, pod=pod-0"
    exit 1
    ;;
esac
