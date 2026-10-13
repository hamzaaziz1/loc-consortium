# Parses network/config/addressing.conf into parallel arrays. Sourced, not run.
#
# Populates ADDR_SUBNET and the parallel arrays ADDR_SERVICES, ADDR_NODES,
# ADDR_IPS, ADDR_RPC_PORTS, ADDR_METRICS_PORTS.
#
# Shared by the generator and the smoke test so that neither has its own idea
# of where a node lives.

addr_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

addr_load() {
  local file="$1"
  [[ -f "$file" ]] || { echo "missing $file" >&2; return 1; }

  ADDR_SUBNET="$(grep -E '^SUBNET=' "$file" | cut -d= -f2)"
  [[ -n "$ADDR_SUBNET" ]] || { echo "no SUBNET= line in $file" >&2; return 1; }

  ADDR_SERVICES=(); ADDR_NODES=(); ADDR_IPS=(); ADDR_RPC_PORTS=(); ADDR_METRICS_PORTS=()
  local service node ip rpc metrics
  while IFS='|' read -r service node ip rpc metrics || [[ -n "${service:-}" ]]; do
    service="$(addr_trim "${service:-}")"
    [[ -z "$service" || "${service:0:1}" == "#" || "$service" == SUBNET=* ]] && continue
    ADDR_SERVICES+=("$service")
    ADDR_NODES+=("$(addr_trim "${node:-}")")
    ADDR_IPS+=("$(addr_trim "${ip:-}")")
    ADDR_RPC_PORTS+=("$(addr_trim "${rpc:-}")")
    ADDR_METRICS_PORTS+=("$(addr_trim "${metrics:-}")")
  done < "$file"
}
