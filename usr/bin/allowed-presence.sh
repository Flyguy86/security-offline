#!/bin/sh
# Tiny presence daemon for GL.iNet/OpenWrt.
# Decides "home"/"away" by checking a list of allowed IPs across one or more subnets.
# Signals used: ARP/MAC, iw station inactivity + RX/TX bytes, and ping fallback.
# Writes mode and details to /tmp/allowed-presence/* (read by mqtt-router).

set -eu

CONF="/etc/allowed-presence.conf"
[ -r "$CONF" ] || { echo "Missing $CONF" >&2; exit 1; }
. "$CONF"

mkdir -p "$STATE_DIR"

lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }
_now() { date +%s; }

# Discover Wi-Fi if not set
discover_wifi() {
  [ -n "${WIFI_IFACES:-}" ] && { echo "$WIFI_IFACES"; return; }
  iw dev 2>/dev/null | awk '/Interface/{print $2}'
}

# Expand allowed IPs from ALLOWED_RANGES (A.B.C.30-49 or A.B.C.42) + ALLOWED_IPS
build_allowed_ips() {
  for R in ${ALLOWED_RANGES:-}; do
    base="${R%.*}"          # A.B.C
    last="${R##*.}"         # 30-49 OR 42
    if echo "$last" | grep -q '-'; then
      start="${last%-*}"; end="${last#*-}"
      i="$start"
      while [ "$i" -le "$end" ]; do
        echo "$base.$i"
        i=$((i+1))
      done
    else
      echo "$base.$last"
    fi
  done
  for ip in ${ALLOWED_IPS:-}; do echo "$ip"; done
}

# Dump Wi-Fi station map: mac|iface|inactive_ms|rx_bytes|tx_bytes|rates
wifi_map_dump() {
  ifaces="$(discover_wifi)"
  for ifc in $ifaces; do
    iw dev "$ifc" station dump 2>/dev/null | awk -v ifc="$ifc" '
      BEGIN{mac="";inactive=0;rx_b=tx_b=0;rxr=txr=""}
      /^Station /{mac=tolower($2); next}
      /inactive time:/{inactive=$3; next}
      /rx bytes:/{rx_b=$3; next}
      /tx bytes:/{tx_b=$3; next}
      /rx bitrate:/{rxr=$3" "$4; next}
      /tx bitrate:/{txr=$3" "$4; next}
      /^$/{
        if(mac!=""){
          printf "%s|%s|%s|%s|%s|%s\n", mac, ifc, inactive, rx_b, tx_b, rxr"/"txr
        }
        mac=""
      }
      END{
        if(mac!=""){
          printf "%s|%s|%s|%s|%s|%s\n", mac, ifc, inactive, rx_b, tx_b, rxr"/"txr
        }
      }'
  done
}

# Quick ping using BusyBox ping
fast_ping() { # $1=ip
  # -W is seconds; round up ms -> s
  ping -c "${PING_TRIES:-1}" -W $(( (PING_TIMEOUT_MS+999)/1000 )) "$1" >/dev/null 2>&1
}

bytes_file_for(){ echo "$STATE_DIR/bytes_$(echo "$1" | tr ':' '_')"; }

# Resolve MAC for an IP (ARP/neighbor)
ip2mac() {
  ip="$1"
  mac="$(ip neigh show "$ip" 2>/dev/null | awk '/lladdr/{print tolower($5)}' | head -n1)"
  if [ -z "${mac:-}" ]; then
    mac="$(awk -v IP="$ip" '$1==IP{print tolower($4)}' /proc/net/arp 2>/dev/null | head -n1 || true)"
  fi
  echo "${mac:-}"
}

# Decide if IP/MAC is online. Prefer Wi-Fi station info; fall back to ping.
is_online() { # $1=ip  $2=mac
  ip="$1"
  mac="$(lower "${2:-}")"

  if [ -n "$mac" ]; then
    line="$(printf "%s\n" "$WIFI_MAP" | grep -F -i "^$mac|" || true)"
    if [ -n "$line" ]; then
      inactive="$(echo "$line" | cut -d'|' -f3)"
      rx_b="$(echo "$line" | cut -d'|' -f4)"
      tx_b="$(echo "$line" | cut -d'|' -f5)"

      # If station appears idle, try ping before calling it offline
      if [ "${WIFI_INACTIVE_MAX_MS:-0}" -gt 0 ] && [ "$inactive" -gt "${WIFI_INACTIVE_MAX_MS:-0}" ]; then
        fast_ping "$ip" && return 0 || return 1
      fi

      if [ "${REQUIRE_ACTIVITY:-0}" -eq 1 ]; then
        f="$(bytes_file_for "$mac")"
        if [ -r "$f" ]; then
          prev_rx="$(cut -d' ' -f1 < "$f")"
          prev_tx="$(cut -d' ' -f2 < "$f")"
          if [ $((rx_b - prev_rx)) -le 0 ] && [ $((tx_b - prev_tx)) -le 0 ]; then
            echo "$rx_b $tx_b" > "$f"
            return 1
          fi
        fi
        echo "$rx_b $tx_b" > "$f"
      fi
      return 0
    fi
  fi

  # No station info → ping fallback
  fast_ping "$ip" && return 0 || return 1
}

# State helpers
load_state(){
  [ -r "$STATE_DIR/state" ] && . "$STATE_DIR/state" || true
  LAST_MODE="${LAST_MODE:-away}"
  LAST_CHANGE="${LAST_CHANGE:-0}"
  LAST_ONLINE_TS="${LAST_ONLINE_TS:-0}"
}
save_state(){
  printf 'LAST_MODE=%s\nLAST_CHANGE=%s\nLAST_ONLINE_TS=%s\n' \
    "$LAST_MODE" "$LAST_CHANGE" "$LAST_ONLINE_TS" > "$STATE_DIR/state"
}
write_mode(){ echo "$1" > "$MODE_FILE"; }
write_detail_json(){ # $1 = JSON items
  printf '{ "ts": %s, "mode": "%s", "items":[%s] }\n' "$NOW" "$LAST_MODE" "$1" > "$DETAIL_FILE"
}

# ---- Main loop ----
load_state
WIFI_MAP="$(wifi_map_dump)"

while :; do
  NOW="$(_now)"

  # Manual override, if present
  if [ -s "$OVERRIDE_FILE" ]; then
    FORCED="$(tr -d ' \t\r\n' < "$OVERRIDE_FILE")"
    case "$FORCED" in
      home|away)
        if [ "$FORCED" != "$LAST_MODE" ]; then
          LAST_MODE="$FORCED"; LAST_CHANGE="$NOW"; save_state; write_mode "$LAST_MODE"
        fi
        sleep "${CHECK_INTERVAL:-3}"
        continue
      ;;
    esac
  fi

  WIFI_MAP="$(wifi_map_dump)"

  ANY_ONLINE=0
  JSON_ITEMS=""
  for ip in $(build_allowed_ips); do
    mac="$(ip2mac "$ip" || true)"
    online=0
    if is_online "$ip" "$mac"; then
      online=1; ANY_ONLINE=1; LAST_ONLINE_TS="$NOW"
    fi

    # Collect compact JSON item for debugging
    rates=""
    if [ -n "$mac" ]; then
      l="$(printf "%s\n" "$WIFI_MAP" | grep -F -i "^$mac|" || true)"
      [ -n "$l" ] && rates="$(echo "$l" | cut -d'|' -f6)"
    fi
    item=$(printf '{"ip":"%s","mac":"%s","online":%s%s}' \
      "$ip" "${mac:-}" "$( [ $online -eq 1 ] && echo true || echo false )" \
      "$( [ -n "$rates" ] && printf ',"rates":"%s"' "$rates" || echo "" )")
    [ -n "$JSON_ITEMS" ] && JSON_ITEMS="$JSON_ITEMS,$item" || JSON_ITEMS="$item"
  done

  # Mode transitions with debounce
  NEW_MODE="$LAST_MODE"
  if [ "$LAST_MODE" = "away" ] && [ "$ANY_ONLINE" -eq 1 ] && [ $((NOW - LAST_CHANGE)) -ge "${DEBOUNCE_HOME:-15}" ]; then
    NEW_MODE="home"; LAST_CHANGE="$NOW"
  elif [ "$LAST_MODE" = "home" ] && [ "$ANY_ONLINE" -eq 0 ] && [ $((NOW - LAST_ONLINE_TS)) -ge "${DEBOUNCE_AWAY:-60}" ]; then
    NEW_MODE="away"; LAST_CHANGE="$NOW"
  fi

  if [ "$NEW_MODE" != "$LAST_MODE" ] || [ ! -s "$MODE_FILE" ]; then
    LAST_MODE="$NEW_MODE"
    write_mode "$LAST_MODE"
  fi

  write_detail_json "$JSON_ITEMS"
  save_state
  sleep "${CHECK_INTERVAL:-3}"
done
