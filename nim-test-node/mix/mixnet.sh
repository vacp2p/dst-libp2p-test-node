#!/bin/bash
# Spin up a local test mixnet of arbitrary size.
#
#   ./mixnet.sh up [N=5] [mode=regular]
#   ./mixnet.sh publish [target=0]
#   ./mixnet.sh logs [pod=pod-0]
#   ./mixnet.sh down
#   ./mixnet.sh smoke         # fast 2-cell check (false/anonymous reject + true/anonymous E2E)
#   ./mixnet.sh smoke-all     # full 6-cell matrix walk
#
# modes: regular | anonymous | off

set -e

IMAGE=${IMAGE:-dst-test-node-mix-shadow:wip}
NETWORK=${NETWORK:-mixnet}
PUBINFOS=${PUBINFOS:-/tmp/mixnet-pubinfos}

# Clean up pods on Ctrl-C so the next invocation isn't blocked by stale containers.
trap 'docker ps -a --filter "name=^pod-" -q | xargs -r docker rm -f >/dev/null 2>&1 || true' INT TERM

cmd_up() {
  local N=${1:-5}
  local MODE=${2:-regular}
  local MIX=${MIX:-true}

  docker network create "$NETWORK" 2>/dev/null || true
  mkdir -p "$PUBINFOS"

  # Launch in parallel so all containers boot at roughly the same time
  # instead of being staggered by a sequential loop. Image's ENV FILEPATH=/data
  # sets the pubInfo dir; only the host volume needs binding here.
  for i in $(seq 0 $((N - 1))); do
    docker run -d \
      --name "pod-$i" --hostname "pod-$i" --network "$NETWORK" \
      -v "$PUBINFOS":/data \
      -e MIXENABLED="$MIX" \
      -e GOSSIPSUBMODE="$MODE" \
      -e PEERS="$N" \
      -e NUMMIX="$N" \
      -e CONNECTTO=3 \
      -e SHADOWENV=true \
      -e MUXER=yamux \
      -e MAXCONNECTIONS=20 \
      -e SELFTRIGGER=true \
      -e STARTSLEEP=15 \
      -e FRAGMENTS=1 \
      --platform linux/amd64 \
      "$IMAGE" > /dev/null &
  done
  wait

  echo "Mixnet ready: $N nodes, mode=$MODE, mix=$MIX"
  echo "  publish:  ./mixnet.sh publish [target]"
  echo "  logs:     ./mixnet.sh logs pod-0"
  echo "  down:     ./mixnet.sh down"
}

cmd_publish() {
  local TARGET=${1:-0}
  docker run --rm --network "$NETWORK" --platform linux/amd64 \
    curlimages/curl:latest \
    -X POST "http://pod-$TARGET:8645/publish" \
    -H "Content-Type: application/json" \
    -d '{"topic":"test","msgSize":1500,"version":'"$(date +%s)"'}'
  echo
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

cmd_smoke() {
  echo "=== Smoke test ==="

  echo "[1/2] Validation: MIXENABLED=false + GOSSIPSUBMODE=anonymous should reject..."
  local VAL_OUT
  VAL_OUT=$(docker run --rm --platform linux/amd64 \
    --hostname pod-0 \
    -e MIXENABLED=false -e GOSSIPSUBMODE=anonymous \
    -e PEERS=5 -e NUMMIX=5 -e CONNECTTO=3 \
    -e SHADOWENV=true -e MUXER=yamux \
    -e MAXCONNECTIONS=20 -e SELFTRIGGER=true -e STARTSLEEP=15 -e FRAGMENTS=1 \
    "$IMAGE" 2>&1 || true)
  if echo "$VAL_OUT" | grep -q "anonymous requires MIXENABLED"; then
    echo "  ok: rejected invalid combo"
  else
    echo "  FAIL: did not reject invalid combo"
    echo "$VAL_OUT" | tail -5
    return 1
  fi

  echo "[2/2] End-to-end: 5 nodes, anonymous, expect message delivery..."
  cmd_down > /dev/null 2>&1 || true
  cmd_up 5 anonymous > /dev/null
  echo "  warmup 60s..."
  sleep 60
  cmd_publish 0 > /dev/null
  sleep 5
  local DELIVERED=0
  for pod in pod-0 pod-1 pod-2 pod-3 pod-4; do
    if docker logs "$pod" 2>&1 | grep -q "Received message"; then
      DELIVERED=$((DELIVERED + 1))
    fi
  done
  cmd_down > /dev/null
  if [ "$DELIVERED" -ge 1 ]; then
    echo "  ok: $DELIVERED/5 pods received message"
    echo "=== Smoke PASS ==="
    return 0
  else
    echo "  FAIL: no pod received message"
    echo "=== Smoke FAIL ==="
    return 1
  fi
}

_count_log_match() {
  # Count pods (pod-0 .. pod-$((N-1))) whose docker logs contain $2.
  local N=$1; local PATTERN=$2; local C=0
  for i in $(seq 0 $((N - 1))); do
    docker logs "pod-$i" 2>&1 | grep -q "$PATTERN" && C=$((C + 1))
  done
  echo "$C"
}

cmd_smoke_all() {
  echo "=== Smoke-all: 6-cell mode matrix walk ==="
  local PASS=0 FAIL=0
  # N=5 satisfies env.nim validation NUMMIX >= PathLength + 2 for the current
  # libp2p-mix pin (PathLength=3). If a pin bump raises PathLength, raise N too.
  local LABEL OUT N=5

  # 1. false/anonymous → startup validation rejects
  LABEL="false/anonymous → reject"
  echo "[1/6] $LABEL"
  OUT=$(docker run --rm --platform linux/amd64 --hostname pod-0 \
    -e MIXENABLED=false -e GOSSIPSUBMODE=anonymous \
    -e PEERS=$N -e NUMMIX=$N -e CONNECTTO=3 \
    -e SHADOWENV=true -e MUXER=yamux \
    -e MAXCONNECTIONS=20 -e SELFTRIGGER=true -e STARTSLEEP=15 -e FRAGMENTS=1 \
    "$IMAGE" 2>&1 || true)
  if echo "$OUT" | grep -q "anonymous requires MIXENABLED"; then
    echo "  PASS"; PASS=$((PASS + 1))
  else
    echo "  FAIL"; FAIL=$((FAIL + 1))
  fi

  # 2. false/off → boots and idles without crash
  LABEL="false/off → silent boot"
  echo "[2/6] $LABEL"
  cmd_down >/dev/null 2>&1 || true
  MIX=false cmd_up $N off >/dev/null
  sleep 25
  if docker ps --filter "name=^pod-0$" --filter "status=running" -q | grep -q .; then
    echo "  PASS"; PASS=$((PASS + 1))
  else
    echo "  FAIL"; FAIL=$((FAIL + 1))
  fi
  cmd_down >/dev/null 2>&1

  # 3. false/regular → GossipSub direct delivery
  LABEL="false/regular → GossipSub direct delivery"
  echo "[3/6] $LABEL"
  cmd_down >/dev/null 2>&1 || true
  MIX=false cmd_up $N regular >/dev/null
  sleep 60
  cmd_publish 0 >/dev/null
  sleep 5
  local D=$(_count_log_match $N "Received message")
  cmd_down >/dev/null 2>&1
  if [ "$D" -ge 1 ]; then
    echo "  PASS ($D/$N delivered)"; PASS=$((PASS + 1))
  else
    echo "  FAIL ($D/$N delivered)"; FAIL=$((FAIL + 1))
  fi

  # 4. true/regular → GossipSub direct + mix-ping running
  LABEL="true/regular → GossipSub direct + mix-ping"
  echo "[4/6] $LABEL"
  cmd_down >/dev/null 2>&1 || true
  cmd_up $N regular >/dev/null
  sleep 90
  cmd_publish 0 >/dev/null
  sleep 5
  D=$(_count_log_match $N "Received message")
  local P=$(_count_log_match $N "mix-ping ok")
  cmd_down >/dev/null 2>&1
  if [ "$D" -ge 1 ] && [ "$P" -ge 1 ]; then
    echo "  PASS ($D/$N delivered, $P/$N pinged)"; PASS=$((PASS + 1))
  else
    echo "  FAIL ($D/$N delivered, $P/$N pinged)"; FAIL=$((FAIL + 1))
  fi

  # 5. true/anonymous → GossipSub-over-mix
  LABEL="true/anonymous → GossipSub-over-mix"
  echo "[5/6] $LABEL"
  cmd_down >/dev/null 2>&1 || true
  cmd_up $N anonymous >/dev/null
  sleep 60
  cmd_publish 0 >/dev/null
  sleep 5
  D=$(_count_log_match $N "Received message")
  cmd_down >/dev/null 2>&1
  if [ "$D" -ge 1 ]; then
    echo "  PASS ($D/$N delivered)"; PASS=$((PASS + 1))
  else
    echo "  FAIL ($D/$N delivered)"; FAIL=$((FAIL + 1))
  fi

  # 6. true/off → pure mixnet (mix-ping is the only traffic)
  LABEL="true/off → pure mixnet (ping-only)"
  echo "[6/6] $LABEL"
  cmd_down >/dev/null 2>&1 || true
  cmd_up $N off >/dev/null
  sleep 90
  P=$(_count_log_match $N "mix-ping ok")
  cmd_down >/dev/null 2>&1
  if [ "$P" -ge 1 ]; then
    echo "  PASS ($P/$N pinged)"; PASS=$((PASS + 1))
  else
    echo "  FAIL ($P/$N pinged)"; FAIL=$((FAIL + 1))
  fi

  echo "=== Smoke-all: $PASS pass, $FAIL fail ==="
  [ "$FAIL" -eq 0 ] && return 0 || return 1
}

case "$1" in
  up)        shift; cmd_up "$@" ;;
  publish)   shift; cmd_publish "$@" ;;
  logs)      shift; cmd_logs "$@" ;;
  down)      cmd_down ;;
  smoke)     cmd_smoke ;;
  smoke-all) cmd_smoke_all ;;
  *)
    echo "Usage: $0 {up [N] [mode]|publish [target]|logs [pod]|down|smoke|smoke-all}"
    echo "  modes: regular | anonymous | off"
    echo "  defaults: N=5, mode=regular, target=0"
    exit 1
    ;;
esac
