#!/bin/bash
set -e

# Apply network shaping via tc netem if environment variables are set.
# Requires NET_ADMIN capability.
#
# LATENCY_MS      - one-way delay in milliseconds (default: 0)
# BANDWIDTH_MBIT  - bandwidth limit in Mbit/s (default: unlimited)
# PACKET_LOSS_PCT - packet loss percentage (default: 0)
# JITTER_MS       - delay jitter in milliseconds (default: 0)
# REORDER_PCT     - packet reorder percentage (default: 0, requires LATENCY_MS)

apply_netem() {
  local iface
  iface=$(ip -o link show | awk -F': ' '!/lo/{gsub(/@.*/, "", $2); print $2; exit}')

  if [ -z "$iface" ]; then
    echo "[entrypoint] WARNING: could not detect network interface, skipping netem"
    return
  fi

  local has_netem=false

  # Build netem parameters
  local netem_args=""
  if [ -n "$LATENCY_MS" ] && [ "$LATENCY_MS" != "0" ]; then
    netem_args="delay ${LATENCY_MS}ms"
    if [ -n "$JITTER_MS" ] && [ "$JITTER_MS" != "0" ]; then
      netem_args="${netem_args} ${JITTER_MS}ms"
    fi
    has_netem=true
  fi

  if [ -n "$PACKET_LOSS_PCT" ] && [ "$PACKET_LOSS_PCT" != "0" ]; then
    netem_args="${netem_args} loss ${PACKET_LOSS_PCT}%"
    has_netem=true
  fi

  if [ -n "$REORDER_PCT" ] && [ "$REORDER_PCT" != "0" ]; then
    # reorder requires delay to be set (reordered packets skip the delay)
    netem_args="${netem_args} reorder ${REORDER_PCT}% 50%"
    has_netem=true
  fi

  # Bandwidth shaping: combine with netem if both are set
  if [ -n "$BANDWIDTH_MBIT" ] && [ "$BANDWIDTH_MBIT" != "0" ]; then
    local rate="${BANDWIDTH_MBIT}mbit"
    # burst = rate * 1ms; latency = 50ms buffer
    local burst_bytes=$(( BANDWIDTH_MBIT * 1000 / 8 ))
    if [ "$burst_bytes" -lt 1600 ]; then
      burst_bytes=1600
    fi

    if [ "$has_netem" = true ]; then
      # Use htb as root, then attach netem + tbf as children
      echo "[entrypoint] Applying netem + bandwidth on $iface: $netem_args rate=${rate}"
      tc qdisc add dev "$iface" root handle 1: netem $netem_args rate "$rate"
    else
      echo "[entrypoint] Applying bandwidth limit on $iface: ${rate}"
      tc qdisc add dev "$iface" root tbf rate "$rate" burst "${burst_bytes}" latency 50ms
    fi
  elif [ "$has_netem" = true ]; then
    echo "[entrypoint] Applying netem on $iface: $netem_args"
    tc qdisc add dev "$iface" root netem $netem_args
  fi
}

# Only apply netem if any shaping var is set
if [ -n "$LATENCY_MS" ] || [ -n "$BANDWIDTH_MBIT" ] || [ -n "$PACKET_LOSS_PCT" ] || [ -n "$REORDER_PCT" ]; then
  apply_netem
fi

# Run the actual command
exec "$@"
