#!/bin/ash
# index-gen.sh — Generate mqtt-http-routes.conf from a tiles-based JSON
# BusyBox/ash + jsonfilter only (GL.iNet/OpenWrt friendly)
#
# Supports your /etc/index-devices.json schema:
# {
#   "mqtt": { "host": "192.168.87.1", "port": 1883 },
#   "tiles": [
#     { "type": "radar",   "device": "mmwave1", ... },
#     { "type": "radar",   "device": "mmwave2", ... },
#     { "type": "tasmota", "device": "tasmota_XYZ", "relay":2, "duration":10, "burst":1, "gap":0.75 },
#     { "type": "shelly",  "device": "shelly1pm-AAAA", "relay":0, "duration":30, "burst":3, "gap":0.30 },
#     ...
#   ]
# }
#
# Usage:
#   index-gen.sh routes [/path/to/config.json] [--write|-w]
#   index-gen.sh urls   [/path/to/config.json]

set -eu

CMD="${1:-routes}"
CFG="/etc/index-devices.json"
OUT="-"

# Args: optional config path + optional --write
if [ $# -ge 2 ]; then
  case "$2" in
    --write|-w) OUT="/etc/mqtt-http-routes.conf" ;;
    *) CFG="$2" ;;
  esac
fi
if [ $# -ge 3 ]; then
  case "$3" in
    --write|-w) OUT="/etc/mqtt-http-routes.conf" ;;
    *) : ;;
  esac
fi

die(){ echo "ERROR: $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

[ -f "$CFG" ] || die "Config not found: $CFG"
have jsonfilter || die "jsonfilter not installed (opkg install jsonfilter)"

JSON="$(cat "$CFG")"

# json getter (returns empty if missing)
jget(){ jsonfilter -s "$JSON" -e "@$1" 2>/dev/null || true; }

# Pull MQTT host/port (with defaults)
HOST="$(jget .mqtt.host)"; [ -z "$HOST" ] && HOST="192.168.87.1"
PORT="$(jget .mqtt.port)"; [ -z "$PORT" ] && PORT="1883"

# Presence JSON path (for mmWave payloads)
PRESENCE_PATH=".R24DVD1.Human.Presence"

INDEX_URL="http://127.0.0.1/cgi-bin/index.cgi"

# Count tiles
tiles_len(){
  i=0
  while :; do
    t="$(jget ".tiles[$i].type")"
    [ -z "$t" ] && break
    i=$((i+1))
  done
  echo "$i"
}

# Emit one start/stop routes pair (literal topic tele/<radar>/SENSOR)
emit_pair_routes(){
  RAD="$1"     # radar device name like mmwave1
  TTYPE="$2"   # shelly|tasmota
  DEV="$3"     # actuator device id (shelly1pm-..., tasmota_...)
  RELAY="$4"   # may be empty -> default per type
  DURA="$5"
  BURST="$6"
  GAP="$7"

  case "$TTYPE" in
    shelly)
      [ -z "$RELAY" ] && RELAY="0"
      [ -z "$DURA"  ] && DURA="30"
      [ -z "$BURST" ] && BURST="3"
      [ -z "$GAP"   ] && GAP="0.30"
      ;;
    tasmota|*)
      [ -z "$RELAY" ] && RELAY="2"
      [ -z "$DURA"  ] && DURA="10"
      [ -z "$BURST" ] && BURST="1"
      [ -z "$GAP"   ] && GAP="0.75"
      ;;
  esac

  TOPIC="tele/$RAD/SENSOR"

  START_QS="api=run&action=start&device=$DEV&type=$TTYPE&relay=$RELAY&duration=$DURA&burst=$BURST&gap=$GAP&host=$HOST&port=$PORT&mode={mode}"
  STOP_QS="api=run&action=stop&device=$DEV&type=$TTYPE&relay=$RELAY&host=$HOST&port=$PORT&mode={mode}"

  REQ_START="json_eq:$PRESENCE_PATH,Occupied"
  REQ_STOP="json_in:$PRESENCE_PATH,Unoccupied|None|Empty"

  # Start when away; Stop in any mode
  echo "$TOPIC|$INDEX_URL|$START_QS|away|$REQ_START"
  echo "$TOPIC|$INDEX_URL|$STOP_QS|any|$REQ_STOP"
}

emit_pair_urls(){
  RAD="$1" TTYPE="$2" DEV="$3" RELAY="$4" DURA="$5" BURST="$6" GAP="$7"
  case "$TTYPE" in
    shelly)
      [ -z "$RELAY" ] && RELAY="0"
      [ -z "$DURA"  ] && DURA="30"
      [ -z "$BURST" ] && BURST="3"
      [ -z "$GAP"   ] && GAP="0.30"
      ;;
    tasmota|*)
      [ -z "$RELAY" ] && RELAY="2"
      [ -z "$DURA"  ] && DURA="10"
      [ -z "$BURST" ] && BURST="1"
      [ -z "$GAP"   ] && GAP="0.75"
      ;;
  esac
  echo "# $RAD -> $DEV ($TTYPE)"
  echo "$INDEX_URL?api=run&action=start&device=$DEV&type=$TTYPE&relay=$RELAY&duration=$DURA&burst=$BURST&gap=$GAP&host=$HOST&port=$PORT"
  echo "$INDEX_URL?api=run&action=stop&device=$DEV&type=$TTYPE&relay=$RELAY&host=$HOST&port=$PORT"
  echo
}

# Build arrays by scanning tiles once
LEN="$(tiles_len)"

RADARS=""
ACTS=""   # newline-separated records: "type|device|relay|duration|burst|gap"

i=0
while [ "$i" -lt "$LEN" ]; do
  TTYPE="$(jget ".tiles[$i].type")"
  DEV="$(jget ".tiles[$i].device")"
  RELAY="$(jget ".tiles[$i].relay")"
  DURA="$(jget ".tiles[$i].duration")"
  BURST="$(jget ".tiles[$i].burst")"
  GAP="$(jget ".tiles[$i].gap")"

  case "$TTYPE" in
    radar)
      # Use the tile device as the radar name; topic is tele/<device>/SENSOR
      RADARS="${RADARS}${DEV}
"
      ;;
    shelly|tasmota)
      ACTS="${ACTS}${TTYPE}|${DEV}|${RELAY}|${DURA}|${BURST}|${GAP}
"
      ;;
    *) : ;;
  esac
  i=$((i+1))
done

# Writer helper
write_or_print(){
  if [ "$OUT" = "-" ]; then
    cat
  else
    sed 's/\r$//' > "$OUT"
    echo "Wrote $OUT"
  fi
}

case "$CMD" in
  routes)
    {
      echo "# topic_filter|url|query_template|mode|require"
      # Uncomment next line to also include a debug echo route at top:
      # echo "tele/#|http://127.0.0.1/cgi-bin/echo.cgi|topic={topic}&t2={t2}&presence={json:$PRESENCE_PATH}&mode={mode}|any|"

      # For each radar, create pairs against every actuator (shelly + tasmota)
      echo "$RADARS" | while IFS= read -r R; do
        [ -z "$R" ] && continue
        echo "$ACTS" | while IFS= read -r rec; do
          [ -z "$rec" ] && continue
          IFS='|' read -r TTYPE ADEV ARELAY ADURA ABURST AGAP <<EOF
$rec
EOF
          emit_pair_routes "$R" "$TTYPE" "$ADEV" "$ARELAY" "$ADURA" "$ABURST" "$AGAP"
        done
      done
    } | write_or_print
    ;;
  urls)
    {
      echo "$RADARS" | while IFS= read -r R; do
        [ -z "$R" ] && continue
        echo "$ACTS" | while IFS= read -r rec; do
          [ -z "$rec" ] && continue
          IFS='|' read -r TTYPE ADEV ARELAY ADURA ABURST AGAP <<EOF
$rec
EOF
          emit_pair_urls "$R" "$TTYPE" "$ADEV" "$ARELAY" "$ADURA" "$ABURST" "$AGAP"
        done
      done
    }
    ;;
  help|-h|--help)
    echo "Usage: $(basename "$0") [routes|urls] [CONFIG_JSON] [--write|-w]" >&2
    exit 0
    ;;
  *)
    echo "Unknown command: $CMD" >&2
    exit 2
    ;;
esac
