#!/bin/ash
# /www/cgi-bin/stop_all.sh  — STOP ALL (BusyBox ash-safe)
# CGI: /cgi-bin/stop_all.sh?all=1[&host=...&port=...]
# Order: kill -> confirm exit -> THEN MQTT OFF

# ---- CGI header ----
echo "Content-Type: application/json"
echo ""

# ---- keep stderr out of JSON ----
exec 2>>/tmp/stop_all.err

# ---- helpers ----
urldecode() { printf '%b' "${1//%/\\x}"; }

# tiny sleep (prefers usleep if present)
HAVE_USLEEP=0
command -v usleep >/dev/null 2>&1 && HAVE_USLEEP=1
sleep_short() { if [ "$HAVE_USLEEP" -eq 1 ]; then usleep 100000; else sleep 0.1; fi; }

# ps alive check that works on BusyBox
is_alive() {
  pid="$1"
  ps | awk '{print $1}' | grep -qx "$pid"
}

term_then_kill() {
  pid="$1"
  kill "$pid" 2>/dev/null || true
  i=0
  while [ $i -lt 4 ]; do
    is_alive "$pid" || return 0
    sleep_short
    i=$((i+1))
  done
  kill -9 "$pid" 2>/dev/null || true
  if [ "$HAVE_USLEEP" -eq 1 ]; then usleep 50000; else sleep 0.05; fi
}

# ---- parse query ----
ALL_RAW="0"; HOST="127.0.0.1"; PORT="1883"
IFS='&'
for kv in ${QUERY_STRING:-}; do
  k="${kv%%=*}"; v="$(urldecode "${kv#*=}")"
  case "$k" in
    all)  ALL_RAW="$v" ;;
    host) HOST="$v" ;;
    port) PORT="$v" ;;
  esac
done
unset IFS

ALL_N="$(printf '%s' "$ALL_RAW" | tr 'A-Z' 'a-z')"
case "$ALL_N" in 1|true|yes|on) ALL=1 ;; *) ALL=0 ;; esac

# ---- MQTT (optional) ----
PUB=""
if command -v mosquitto_pub >/dev/null 2>&1; then
  PUB="mosquitto_pub -h $HOST -p $PORT -q 0 -t"
  [ -n "${MQTT_USER:-}" ] && PUB="$PUB -u $MQTT_USER"
  [ -n "${MQTT_PASS:-}" ] && PUB="$PUB -P $MQTT_PASS"
fi
publish_off_shelly()  { dev="$1"; rel="$2"; if [ -n "$PUB" ]; then sh -c "$PUB 'shellies/$dev/relay/$rel/command' -m off >/dev/null 2>&1"; fi; }
publish_off_tasmota() { dev="$1"; rel="$2"; if [ -n "$PUB" ]; then sh -c "$PUB 'cmnd/$dev/POWER$rel' -m OFF >/dev/null 2>&1"; fi; }

# ---- STOP ALL path ----
FLAG_STATUS="skipped"; S_DONE=0; T_DONE=0
if [ "$ALL" -eq 1 ]; then
  FLAG="/tmp/strobe_STOPALL"
  rm -f "$FLAG" 2>/dev/null || true
  if touch "$FLAG" 2>/dev/null; then
    TS="$(date 2>/dev/null || cat /proc/uptime 2>/dev/null || echo now)"
    echo "STOPALL set at: $TS" > "$FLAG" 2>/dev/null || true
    FLAG_STATUS="created"
  else
    FLAG_STATUS="failed"
  fi

  # Gather PID files safely (avoid redirection on 'for' lines)
  set -- /tmp/strobe_*_*_*.pid
  for pidf in "$@"; do
    [ -f "$pidf" ] || continue
    base="$(basename "$pidf" .pid)"   # strobe_type_device_relay
    rest="${base#strobe_}"            # type_device_relay
    type="${rest%%_*}"
    rest2="${rest#${type}_}"
    rel="${rest2##*_}"
    dev="${rest2%_*}"

    # Kill first
    pid="$(cat "$pidf" 2>/dev/null || echo)"
    [ -n "$pid" ] && term_then_kill "$pid"

    # Extra safety kill by pattern (best effort)
    busybox pkill -f "strobe_burst_mqtt.sh start ${type} ${dev} ${rel} " 2>/dev/null || true

    # THEN force OFF
    if [ "$type" = "shelly" ]; then
      publish_off_shelly "$dev" "$rel"; S_DONE=$((S_DONE+1))
    else
      publish_off_tasmota "$dev" "$rel"; T_DONE=$((T_DONE+1))
    fi
  done
fi

# ---- JSON (always complete) ----
printf '{'
printf '"ok":true,"order":"killed_then_OFF","stopall_flag":"%s","mqtt_host":"%s","mqtt_port":"%s",' "$FLAG_STATUS" "$HOST" "$PORT"
printf '"shelly_processed":%s,"tasmota_processed":%s' "$S_DONE" "$T_DONE"
printf '}\n'
