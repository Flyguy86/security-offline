#!/bin/ash
# Unified Shelly/Tasmota MQTT strobe — CGI/CLI, PID/STOP-aware, finishes OFF.
# ACTIONS: start (default), stop
#   Shelly topics:  shellies/<device>/relay/<relay>/command  payload: on/off/toggle
#   Tasmota topics: cmnd/<device>/POWER<relay>               payload: ON/OFF/TOGGLE

set -eu

# ---------- helpers ----------
urldecode(){ printf '%b' "${1//%/\\x}"; }
emit_json(){ echo "Content-Type: application/json"; echo ""; echo "$1"; }
now_s(){ cut -d'.' -f1 < /proc/uptime; }
fsleep(){ command -v usleep >/dev/null 2>&1 && usleep "$(awk -v s="$1" 'BEGIN{printf("%d", s*1000000)}')" || sleep "$1"; }

parse_qs() {
  [ -z "${QUERY_STRING:-}" ] && return 0
  local kv k v; IFS='&'
  for kv in $QUERY_STRING; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in
      action)   ACTION="$(urldecode "$v")" ;;
      type)     TYPE="$(urldecode "$v")" ;;
      device)   DEVICE="$(urldecode "$v")" ;;
      relay)    RELAY="$(urldecode "$v")" ;;
      duration) DURATION="$(urldecode "$v")" ;;
      burst)    BURST="$(urldecode "$v")" ;;
      gap)      GAP="$(urldecode "$v")" ;;
      host)     HOST="$(urldecode "$v")" ;;
      port)     PORT="$(urldecode "$v")" ;;
    esac
  done
  unset IFS
}

# ---------- params (CLI first, then CGI override) ----------
ACTION="${1:-}";  TYPE="${2:-}";  DEVICE="${3:-}";  RELAY="${4:-}"
DURATION="${5:-}"; BURST="${6:-}"; GAP="${7:-}"; HOST="${8:-}"; PORT="${9:-}"
[ -n "${QUERY_STRING:-}" ] && parse_qs

# defaults
: "${ACTION:=${ACTION:-start}}"
: "${TYPE:=${TYPE:-shelly}}"
: "${DEVICE:=${DEVICE:-}}"
: "${RELAY:=${RELAY:-0}}"
: "${DURATION:=${DURATION:-10}}"
: "${BURST:=${BURST:-4}}"
: "${GAP:=${GAP:-0.25}}"
: "${HOST:=${HOST:-127.0.0.1}}"
: "${PORT:=${PORT:-1883}}"

# sanitize relay numeric (0..8 typical)
case "$RELAY" in ''|*[!0-9]*) RELAY="0";; esac

KEY="${TYPE}_${DEVICE}_${RELAY}"
PIDFILE="/tmp/strobe_${KEY}.pid"
STOPFILE="/tmp/strobe_${KEY}.stop"
STOPFILE_COMPAT="/tmp/strobe_${TYPE}_${DEVICE}.stop"   # compat: no-relay variant
LOGFILE="/tmp/strobe_${KEY}.log"
STOPALL_FLAG="/tmp/strobe_STOPALL"

# ---------- topics / payload words ----------
case "$TYPE" in
  shelly)
    topic_cmd="shellies/$DEVICE/relay/$RELAY/command"
    topic_stat="shellies/$DEVICE/relay/$RELAY"
    topic_lwt="shellies/$DEVICE/online"
    WORD_ON="on"; WORD_OFF="off"; WORD_TOGGLE="toggle"
    ;;
  tasmota)
    topic_cmd="cmnd/$DEVICE/POWER$RELAY"
    topic_stat="stat/$DEVICE/POWER$RELAY"
    topic_lwt="tele/$DEVICE/LWT"
    WORD_ON="ON"; WORD_OFF="OFF"; WORD_TOGGLE="TOGGLE"
    ;;
  *) [ -n "${REQUEST_METHOD:-}" ] && emit_json "{\"ok\":false,\"error\":\"unsupported type: $TYPE\"}" || echo "unsupported type $TYPE" >&2; exit 0;;
esac

# ---------- deps ----------
if ! command -v mosquitto_pub >/dev/null 2>&1; then
  [ -n "${REQUEST_METHOD:-}" ] && emit_json '{"ok":false,"error":"mosquitto_pub not found","hint":"opkg install mosquitto-client-nossl"}' || echo "mosquitto_pub not found" >&2
  exit 0
fi
command -v mosquitto_sub >/dev/null 2>&1 || true
PUB="mosquitto_pub -h $HOST -p $PORT -q 0 -t"
[ -n "${MQTT_USER:-}" ] && PUB="$PUB -u $MQTT_USER"
[ -n "${MQTT_PASS:-}" ] && PUB="$PUB -P $MQTT_PASS"

WATCH="${WATCH:-0}"

# ---------- ACTION=stop ----------
if [ "$ACTION" = "stop" ]; then
  : >"$STOPFILE" 2>/dev/null || true
  : >"$STOPFILE_COMPAT" 2>/dev/null || true
  if [ -f "$PIDFILE" ]; then
    pid="$(cat "$PIDFILE" 2>/dev/null || echo)"; [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  fi
  # kill by pattern as fallback
  busybox pkill -f "strobe_burst_mqtt.sh start ${TYPE} ${DEVICE} ${RELAY} " 2>/dev/null || true
  # then force OFF
  $PUB "$topic_cmd" -m "$WORD_OFF" >/dev/null 2>&1 || true
  [ -n "${REQUEST_METHOD:-}" ] && emit_json "{\"ok\":true,\"stopped\":true,\"key\":\"$KEY\"}" || echo "stopped $KEY"
  exit 0
fi

# ---------- ACTION=start : CLEAR global STOPALL, then start ----------
if [ "$ACTION" = "start" ]; then
  # Clear global stop-all flag so new strobes can run
  rm -f "$STOPALL_FLAG" 2>/dev/null || true
fi

# If CGI front door, spawn worker and return immediately
if [ -n "${REQUEST_METHOD:-}" ] && [ "${RUN_MODE:-}" != "worker" ]; then
  # stop any previous run for same key
  [ -f "$PIDFILE" ] && { pidold="$(cat "$PIDFILE" 2>/dev/null || echo)"; [ -n "$pidold" ] && kill "$pidold" 2>/dev/null || true; }
  rm -f "$STOPFILE" "$STOPFILE_COMPAT" 2>/dev/null || true

  ( RUN_MODE=worker "$0" start "$TYPE" "$DEVICE" "$RELAY" "$DURATION" "$BURST" "$GAP" "$HOST" "$PORT" >>"$LOGFILE" 2>&1 & echo $! >"$PIDFILE" ) &
  fsleep 0.05
  pid="$(cat "$PIDFILE" 2>/dev/null || echo 0)"
  emit_json "{\"ok\":true,\"started\":true,\"key\":\"$KEY\",\"pid\":$pid,\"topic\":\"$topic_cmd\",\"duration\":$DURATION,\"burst\":$BURST,\"gap\":$GAP}"
  exit 0
fi

# ---------- worker mode ----------
cleanup(){
  $PUB "$topic_cmd" -m "$WORD_OFF" >/dev/null 2>&1 || :
  rm -f "$PIDFILE" "$STOPFILE" "$STOPFILE_COMPAT" 2>/dev/null || :
}
trap cleanup INT TERM EXIT

SUB_PID=""
if [ "$WATCH" = "1" ] && command -v mosquitto_sub >/dev/null 2>&1; then
  sh -c "mosquitto_sub -h '$HOST' -p '$PORT' ${MQTT_USER:+-u '$MQTT_USER'} ${MQTT_PASS:+-P '$MQTT_PASS'} -t '$topic_stat' -t '$topic_lwt' -v" &
  SUB_PID="$!"
fi

# baseline OFF
$PUB "$topic_cmd" -m "$WORD_OFF" >/dev/null 2>&1 || :

start_ts="$(now_s)"
end_ts=$(( start_ts + ${DURATION%.*} ))

while :; do
  # honor any stop flags (per-device or global)
  if [ -f "$STOPFILE" ] || [ -f "$STOPFILE_COMPAT" ] || [ -f "$STOPALL_FLAG" ]; then
    break
  fi
  now="$(now_s)"; [ "$now" -ge "$end_ts" ] && break

  i=1
  while [ "$i" -le "${BURST%.*}" ]; do
    sh -c "$PUB '$topic_cmd' -m '$WORD_TOGGLE' >/dev/null 2>&1" &
    i=$((i+1))
  done
  wait
  fsleep "$GAP"
done

[ -n "$SUB_PID" ] && kill "$SUB_PID" 2>/dev/null || :
exit 0