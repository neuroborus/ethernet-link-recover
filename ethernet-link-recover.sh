#!/usr/bin/env bash
# Recover Ethernet link (YT6801 / NetworkManager): re-seat interface, wait for
# carrier, optionally reload driver, bring connection up by UUID + ifname.
set -euo pipefail

log() { printf '[*] %s\n' "$*"; }
err() { printf '[!] %s\n' "$*" >&2; }

detect_iface() {
  local ifaces
  mapfile -t ifaces < <(
    nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="ethernet"{print $1}'
  )

  if [[ ${#ifaces[@]} -eq 0 ]]; then
    err "No ethernet interfaces found"
    return 1
  fi

  if [[ ${#ifaces[@]} -eq 1 ]]; then
    printf '%s\n' "${ifaces[0]}"
    return 0
  fi

  # Prefer yt6801 if present
  local iface driver
  for iface in "${ifaces[@]}"; do
    driver="$(ethtool -i "$iface" 2>/dev/null | awk -F': ' '/^driver:/{print $2}')"
    if [[ "$driver" == "yt6801" ]]; then
      printf '%s\n' "$iface"
      return 0
    fi
  done

  # Prefer active ethernet connection
  local active
  active="$(nmcli -t -f DEVICE,TYPE,STATE device status | awk -F: '$2=="ethernet" && $3 ~ /^connected|connecting|disconnected|unavailable$/ {print $1; exit}')"
  if [[ -n "${active:-}" ]]; then
    printf '%s\n' "$active"
    return 0
  fi

  err "Multiple ethernet interfaces found, cannot choose safely"
  return 1
}

detect_driver() {
  local iface="$1"
  ethtool -i "$iface" 2>/dev/null | awk -F': ' '/^driver:/{print $2; exit}'
}

# Standalone wired profile for this NIC (skip bridge/docker slaves: they have
# connection.master / connection.slave-type set and break `connection up`).
connection_uuid_suitable_for_iface() {
  local uuid="$1" iface="$2"
  local typ bound master slave

  typ="$(nmcli -g connection.type connection show uuid "$uuid" 2>/dev/null | head -n1 | xargs || true)"
  [[ "$typ" == "802-3-ethernet" ]] || return 1

  bound="$(nmcli -g connection.interface-name connection show uuid "$uuid" 2>/dev/null | head -n1 | xargs || true)"
  [[ -z "$bound" || "$bound" == "--" || "$bound" == "$iface" ]] || return 1

  master="$(nmcli -g connection.master connection show uuid "$uuid" 2>/dev/null | head -n1 | xargs || true)"
  slave="$(nmcli -g connection.slave-type connection show uuid "$uuid" 2>/dev/null | head -n1 | xargs || true)"
  [[ -z "$slave" || "$slave" == "--" ]] || return 1
  [[ -z "$master" || "$master" == "--" ]] || return 1
  return 0
}

find_active_profile_uuid() {
  local iface="$1"
  local out

  # Authoritative: UUID of the connection actually bound to this NIC (avoids
  # ambiguous names and avoids stale "saved" profiles that share interface-name).
  out="$(nmcli -g GENERAL.CON-UUID device show "$iface" 2>/dev/null | head -n1 | xargs)" || true
  if [[ -n "${out:-}" && "$out" != "--" ]] && connection_uuid_suitable_for_iface "$out" "$iface"; then
    printf '%s\n' "$out"
    return 0
  fi

  # Fallback: tabular --active (TYPE is often "802-3-ethernet", not "ethernet").
  out="$(
    nmcli -t -f UUID,TYPE,DEVICE connection show --active \
      | awk -F: -v iface="$iface" \
        '($2=="ethernet" || $2=="802-3-ethernet") && $3==iface {print $1; exit}'
  )" || true
  if [[ -n "${out:-}" ]] && connection_uuid_suitable_for_iface "$out" "$iface"; then
    printf '%s\n' "$out"
    return 0
  fi
  return 1
}

# Resolve by UUID: connection.id / NAME are not guaranteed unique; activation by
# UUID avoids nmcli binding the wrong profile (e.g. Wi‑Fi vs Ethernet name clash).
find_saved_profile_uuid() {
  local iface="$1"
  local uuid type bound_if cid master slave fallback=""

  while IFS= read -r uuid; do
    [[ -z "${uuid:-}" ]] && continue
    type="$(nmcli -g connection.type connection show uuid "$uuid" 2>/dev/null || true)"
    bound_if="$(nmcli -g connection.interface-name connection show uuid "$uuid" 2>/dev/null | head -n1 | xargs || true)"
    [[ "$type" != "802-3-ethernet" || "$bound_if" != "$iface" ]] && continue

    master="$(nmcli -g connection.master connection show uuid "$uuid" 2>/dev/null | head -n1 | xargs || true)"
    slave="$(nmcli -g connection.slave-type connection show uuid "$uuid" 2>/dev/null | head -n1 | xargs || true)"
    [[ -n "$slave" && "$slave" != "--" ]] && continue
    [[ -n "$master" && "$master" != "--" ]] && continue

    cid="$(nmcli -g connection.id connection show uuid "$uuid" 2>/dev/null || true)"
    if [[ "$cid" == "$iface" ]]; then
      printf '%s\n' "$uuid"
      return 0
    fi
    [[ -z "${fallback:-}" ]] && fallback="$uuid"
  done < <(nmcli -t -f UUID connection show)

  if [[ -n "${fallback:-}" ]]; then
    printf '%s\n' "$fallback"
    return 0
  fi
  return 1
}

find_or_create_profile_uuid() {
  local iface="$1"
  local uuid con_name="autorecover-$iface"

  uuid="$(find_active_profile_uuid "$iface" || true)"
  if [[ -n "${uuid:-}" ]]; then
    printf '%s\n' "$uuid"
    return 0
  fi

  uuid="$(find_saved_profile_uuid "$iface" || true)"
  if [[ -n "${uuid:-}" ]]; then
    printf '%s\n' "$uuid"
    return 0
  fi

  nmcli connection add \
    type ethernet \
    ifname "$iface" \
    con-name "$con_name" \
    ipv4.method auto \
    ipv6.method auto \
    connection.autoconnect yes >/dev/null

  nmcli -g connection.uuid connection show "$con_name"
}

carrier_of() {
  local iface="$1"
  cat "/sys/class/net/$iface/carrier" 2>/dev/null || echo "0"
}

wait_for_carrier() {
  local iface="$1" timeout="${2:-10}" i
  for (( i = 0; i < timeout; i++ )); do
    [[ "$(carrier_of "$iface")" == "1" ]] && return 0
    sleep 1
  done
  return 1
}

soft_recover() {
  local iface="$1"
  sudo ip link set "$iface" down || true
  sleep 1
  sudo ip link set "$iface" up || true
}

reload_driver() {
  local driver="$1"
  [[ -z "$driver" ]] && return 0
  sudo modprobe -r "$driver" || true
  sleep 1
  sudo modprobe "$driver" || true
  sleep 2
}

# Activate by UUID and pin netdev (avoids NM picking the wrong device).
bring_up_profile() {
  local profile_uuid="$1" iface="$2"
  nmcli connection up uuid "$profile_uuid" ifname "$iface" || true
  sleep 2
}

main() {
  local iface driver profile_uuid profile_id carrier

  iface="$(detect_iface)"
  driver="$(detect_driver "$iface")"

  profile_uuid="$(find_or_create_profile_uuid "$iface")"
  profile_id="$(nmcli -g connection.id connection show uuid "$profile_uuid")"

  log "Interface: $iface"
  log "Driver: ${driver:-unknown}"
  log "Profile ID: $profile_id"
  log "Profile UUID: $profile_uuid"

  carrier="$(carrier_of "$iface")"
  log "Carrier before recovery: $carrier"

  soft_recover "$iface"

  if wait_for_carrier "$iface" 10; then
    log "Carrier restored after soft recovery"
    bring_up_profile "$profile_uuid" "$iface"
  else
    log "Soft recovery did not restore carrier, reloading driver"
    reload_driver "$driver"
    soft_recover "$iface"

    if wait_for_carrier "$iface" 15; then
      log "Carrier restored after driver reload"
      bring_up_profile "$profile_uuid" "$iface"
    else
      log "Carrier still absent after driver reload"
    fi
  fi

  log "Final device status:"
  nmcli device status
  ip link show "$iface"
  printf 'carrier=%s\n' "$(carrier_of "$iface")"
}

main "$@"
