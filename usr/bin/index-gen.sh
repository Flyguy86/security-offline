#!/bin/ash
# Generate /etc/mqtt-http-routes.conf lines from /etc/index-devices.json
# BusyBox/ash + jsonfilter (no jq). Works on GL.iNet/OpenWrt.

set -eu

# --- defaults ---
CFG="/etc/index-devices.json"
OUT="-"
CMD="${1:-routes}"   # routes | urls | help
[ $# -ge 2 ] && { case "$2" in --write|-w) OUT="/etc/mqtt-http-routes.conf";; *) CFG="$2";; esac
[ $# -ge 3 ] && { case "$3" in --write|-w) OUT="/etc/mqtt-http-routes.conf";; *) :;; esac

die(){ echo "ERROR: $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

[ -f "$CFG" ] || die "Config not found: $CFG"
have jsonfilter || die "jsonfilter not installed (opkg install jsonfilter)"

# Read entire JSON once
JSON="$(cat "$CFG")"

# --- helpers ---
# jget <json-pointer> -> value-or-empty
jget() { jsonfilter -s "$JSON" -e "@$1" 2>/dev/null || true; }

# Loop over array indexes until empty
# usage: for_each "path.to.array" callback_name
for_each(){
  _arr="$1"; _cb="$2"
  i=0
  while :; do
    testval="$(jget ".$_arr[$i]")"
    [ -z "$testval" ] && break
    "$_cb" "$i"
    i=$((i+1))
  done
}

# URL builder pieces
HOST="$(jget .host)"; [ -z "$HOST" ] && HOST="192.168.87.1"
PORT="$(jget .port)"; [ -z "$PORT" ] && PORT="1883"
INDEX_URL="http://127.0.0.1/cgi-bin/index.cgi"
PRESENCE_PATH="$(jget .presence_path)"; [ -z "$PRESENCE_PATH" ] && PRESENCE_PATH=".R24DVD1.Human.Presence"

# Dict lookups for targets by name
# get_target <name> <field>
get_target(){
  _name="$1"; _field="$2"
  i=0
  while :; do
    nm="$(jget .targets[$i].name)"; [ -z "$nm" ] && break
    if [ "$nm" = "$_name" ]; then
      jget ".targets[$i].$_field"
      return 0
    fi
    i=$((i+1))
  done
  return 1
}

# Emit a single routes pair (start/stop) for a binding row
emit_binding(){
  idx="$1"
  SENSOR_NAME="$(jget .bindings[$idx].sensor)"
  TARGET_NAME="$(jget .bindings[$idx].target)"
  START_MODE="$(jget .bindings[$idx].start_mode)"; [ -z "$START_MODE" ] && START_MODE="away"
  STOP_MODE="$(jget .bindings[$idx].stop_mode)";   [ -z "$STOP_MODE" ]  && STOP_MODE="any"

  # Resolve sensor topic (literal topic recommended)
  # Prefer sensor.topic; else construct tele/<sensor>/SENSOR
  SENSOR_TOPIC="$(jget ".sensors[] | select(.name==\"$SENSOR_NAME\").topic" 2>/dev/null || true)"
  # jsonfilter doesn't support that select syntax; do manual scan:
  if [ -z "$SENSOR_TOPIC" ]; then
    j=0
    while :; do
      sn="$(jget .sensors[$j].name)"; [ -z "$sn" ] && break
      if [ "$sn" = "$SENSOR_NAME" ]; then
        SENSOR_TOPIC="$(jget .sensors[$j].topic)"
        [ -z "$SENSOR_TOPIC" ] && SENSOR_TOPIC="tele/$SENSOR_NAME/SENSOR"
        break
      fi
      j=$((j+1))
    done
  fi
  [ -z "$SENSOR_TOPIC" ] && SENSOR_TOPIC="tele/$SENSOR_NAME/SENSOR"

  # Target fields (with per-type defaults)
  DEV="$(get_target "$TARGET_NAME" device || true)"
  TYP="$(get_target "$TARGET_NAME" type   || true)"; [ -z "$TYP" ] && TYP="tasmota"
  RELAY="$(get_target "$TARGET_NAME" relay || true)"
  DURA="$(get_target "$TARGET_NAME" duration || true)"
  BURST="$(get_target "$TARGET_NAME" burst || true)"
  GAP="$(get_target "$TARGET_NAME" gap || true)"

  case "$TYP" in
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

  # Routes lines
  START_QS="api=run&action=start&device=$DEV&type=$TYP&relay=$RELAY&duration=$DURA&burst=$BURST&gap=$GAP&host=$HOST&port=$PORT&mode={mode}"
  STOP_QS="api=run&action=stop&device=$DEV&type=$TYP&relay=$RELAY&host=$HOST&port=$PORT&mode={mode}"

  # Filters
  REQ_START="json_eq:$PRESENCE_PATH,Occupied"
  REQ_STOP="json_in:$PRESENCE_PATH,Unoccupied|None|Empty"

  echo "$SENSOR_TOPIC|$INDEX_URL|$START_QS|$START_MODE|$REQ_START"
  echo "$SENSOR_TOPIC|$INDEX_URL|$STOP_QS|$STOP_MODE|$REQ_STOP"
}

# Optional: emit simple test URLs (no routes), for manual wget
emit_urls(){
  for_each "bindings" emit_url_pair
}
emit_url_pair(){
  idx="$1"
  SENSOR_NAME="$(jget .bindings[$idx].sensor)"
  TARGET_NAME="$(jget .bindings[$idx].target)"
  SENSOR_TOPIC="$(jget .sensors[$idx].topic || true)"
  [ -z "$SENSOR_TOPIC" ] && SENSOR_TOPIC="tele/$SENSOR_NAME/SENSOR"

  DEV="$(get_target "$TARGET_NAME" device || true)"
  TYP="$(get_target "$TARGET_NAME" type   || true)"; [ -z "$TYP" ] && TYP="tasmota"
  RELAY="$(get_target "$TARGET_NAME" relay || true)"
  DURA="$(get_target "$TARGET_NAME" duration || true)"
  BURST="$(get_target "$TARGET_NAME" burst || true)"
  GAP="$(get_target "$TARGET_NAME" gap || true)"

  case "$TYP" in
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

  echo "# $SENSOR_NAME -> $TARGET_NAME"
  echo "http://127.0.0.1/cgi-bin/index.cgi?api=run&action=start&device=$DEV&type=$TYP&relay=$RELAY&duration=$DURA&burst=$BURST&gap=$GAP&host=$HOST&port=$PORT"
  echo "http://127.0.0.1/cgi-bin/index.cgi?api=run&action=stop&device=$DEV&type=$TYP&relay=$RELAY&host=$HOST&port=$PORT"
  echo
}

usage(){
  cat <<USAGE >&2
Usage: index-gen.sh [routes|urls|help] [CONFIG_JSON] [--write|-w]

  routes        Print mqtt-http-routes.conf lines (to stdout by default)
                Use --write to save into /etc/mqtt-http-routes.conf
  urls          Print plain index.cgi start/stop URLs (for manual testing)
  help          Show this help

Default CONFIG_JSON is /etc/index-devices.json
USAGE
  exit 1
}

# --- main ---
case "$CMD" in
  help|-h|--help) usage ;;
  routes)
    {
      echo "# topic_filter|url|query_template|mode|require"
      # Optional: a debug echo route at the top (commented; uncomment if needed)
      # echo "tele/#|http://127.0.0.1/cgi-bin/echo.cgi|topic={topic}&t2={t2}&presence={json:$PRESENCE_PATH}&mode={mode}|any|"
      for_each "bindings" emit_binding
    } | if [ "$OUT" = "-" ]; then cat; else
          # Normalize CRLF and write
          sed 's/\r$//' > "$OUT"
          echo "Wrote $OUT"
        fi
    ;;
  urls) emit_urls ;;
  *) usage ;;
esac
