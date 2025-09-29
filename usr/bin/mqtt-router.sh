# topic_filter|url|query_template|mode|require
#tele/#|http://127.0.0.1/cgi-bin/echo.cgi|topic={topic}&t1={t1}&t2={t2}&t3={t3}&mode={mode}|any|
# (add your real routes under this; leave this at the top while debugging)
tele/mmwave1/SENSOR|http://127.0.0.1/cgi-bin/index.cgi|api=run&action=start&device=shelly1pm-C82B961DD588&type=shelly&relay=0&duration=30&burst=2&gap=0.50&host=192.168.87.1&port=1883&mode={mode}|away|json_eq:.R24DVD1.Human.Presence,Occupied
tele/mmwave1/SENSOR|http://127.0.0.1/cgi-bin/index.cgi|api=run&action=stop&device=shelly1pm-C82B961DD588&type=shelly&relay=0&host=192.168.87.1&port=1883&mode={mode}|any|json_in:.R24DVD1.Human.Presence,Unoccupied|None|Empty

root@GL-AR750S:~# ls
README-br-guest.md    README-mqqt-alarm.md  find_interface
root@GL-AR750S:~# cat /usr/bin/mqtt-router.sh
#!/bin/sh
# MQTT → HTTP router for GL.iNET/OpenWrt (sed-free, POSIX-only, service-safe)
# Columns: topic_filter | url | query_template | mode | require
# require:  json_eq:.path,val   |  json_in:.path,val1|val2|...   |  payload_eq:VAL   |  tN_eq:seg
# Templating: {mode} {topic} {payload} {t1..t10} {json:.path}

# ---------- config / debug ----------
set -u   # (NO -e) do not exit on non-zero
BROKER="${BROKER:-127.0.0.1}"
ROUTES="${ROUTES:-/etc/mqtt-http-routes.conf}"
MODE_FILE="${MODE_FILE:-/tmp/allowed-presence/mode}"
DEFAULT_MODE="${DEFAULT_MODE:-away}"
DEBUG="${DEBUG:-0}"

dbg(){ [ "$DEBUG" = "1" ] && echo "$(date '+%F %T') [DBG]" "$@" >&2; }
log(){ echo "$(date '+%F %T')" "$@" >> /tmp/mqtt-router.log; }
lower(){ echo "$1" | tr '[:upper:]' '[:lower:]'; }
urlencode(){ awk 'BEGIN{for(i=0;i<256;i++)hex[sprintf("%c",i)]=i}
{for(i=1;i<=length($0);i++){c=substr($0,i,1); if(c ~ /[A-Za-z0-9_.~-]/) printf "%s", c; else printf "%%%02X", hex[c]}}' <<EOF
$1
EOF
}
json_get(){ jsonfilter -s "$payload" -e "@$1" 2>/dev/null; }
current_mode(){ m="$(cat "$MODE_FILE" 2>/dev/null || true)"; case "$m" in home|away) echo "$m";; *) echo "$DEFAULT_MODE";; esac; }
mqtt_match(){ f="$1"; t="$2"
  awk -v F="$f" -v T="$t" '
  function splitpath(x,A){return split(x,A,"/")}
  BEGIN{nf=splitpath(F,FF);nt=splitpath(T,TT);i=1;j=1;
    while(1){
      if(i>nf&&j>nt){print 1;exit}
      if(i>nf&&j<=nt){print 0;exit}
      seg=FF[i]
      if(seg=="#"){print 1;exit}
      if(seg=="+"){if(j>nt){print 0;exit}i++;j++;continue}
      if(j>nt){print 0;exit}
      if(seg!=TT[j]){print 0;exit}
      i++;j++;
    }}'
}

# --- single-instance lock ---
LOCKDIR="/var/run/mqtt-router.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  echo "$(date '+%F %T') already running; exiting" >> /tmp/mqtt-router.log
  exit 0
fi
trap 'rmdir "$LOCKDIR"' EXIT INT TERM


require_ok(){
  REQ_REASON=""; req="$1"; [ -z "${req// }" ] && return 0
  case "$req" in
    json_eq:*)
      rest="${req#json_eq:}"; key="${rest%%,*}"; expect="${rest#*,}"
      actual="$(json_get "$key")"
      [ "$(lower "$actual")" = "$(lower "$expect")" ] && return 0 || { REQ_REASON="json_eq FAIL $key='$actual'!='$expect'"; return 1; } ;;
    json_in:*)
      rest="${req#json_in:}"; key="${rest%%,*}"; list="${rest#*,}"
      actual="$(lower "$(json_get "$key")")"; OLDIFS="$IFS"; IFS='|'; set -- $list; IFS="$OLDIFS"
      for v in "$@"; do [ "$actual" = "$(lower "$v")" ] && return 0; done
      REQ_REASON="json_in FAIL $key='${actual:-<nil>}' not in '$list'"; return 1 ;;
    payload_eq:*)
      expect="$(echo "${req#payload_eq:}" | tr -d '[:space:]')"
      got="$(echo "$payload" | tr -d '[:space:]' | lower)"
      [ "$got" = "$(lower "$expect")" ] && return 0 || { REQ_REASON="payload_eq FAIL got='${got:-<nil>}' expect='$expect'"; return 1; } ;;
    t?_eq:*|t??_eq:*)
      seg="${req%%_*}"; seg="${seg#t}"; expect="${req#*:}"; eval "segval=\${t$seg:-}"
      [ "$segval" = "$expect" ] && return 0 || { REQ_REASON="t${seg}_eq FAIL '$segval'!='$expect'"; return 1; } ;;
    *) return 0 ;;
  esac
}
expand_json_tokens(){
  _s="$1"
  while echo "$_s" | grep -q '{json:'; do
    key="$(awk -v s="$_s" 'match(s,/\{json:[^}]+\}/){print substr(s,RSTART+6,RLENGTH-7); exit}')"
    [ -z "$key" ] && break
    val="$(json_get "$key")"; enc="$(urlencode "$val")"
    tok="{json:$key}"; _s="${_s//$tok/$enc}"
  done
  echo "$_s"
}
prep_routes(){
  awk -F'|' '
  function trim(x){ gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", x); return x }
  /^[ \t]*#/ {next} /^[ \t]*$/ {next}
  { f=trim($1); u=trim($2); q=trim($3); m=trim($4); r=trim($5); if(m=="") m="any"; print f "|" u "|" q "|" m "|" r }
  ' "$ROUTES"
}

log "mqtt-router start broker=$BROKER routes=$ROUTES"
dbg "service start broker=$BROKER routes=$ROUTES DEBUG=$DEBUG"

# ---------- resilient subscriber loop ----------
while :; do
  SUB="mosquitto_sub -h \"$BROKER\" -v -t \"#\""
  [ -n "${MOSQ_USER:-}" ] && SUB="$SUB -u \"$MOSQ_USER\""
  [ -n "${MOSQ_PASS:-}" ] && SUB="$SUB -P \"$MOSQ_PASS\""
  log "subscribing: $SUB"
  dbg "subscribing: $SUB"

  # run subscriber; if it dies, we loop & retry after short sleep
  eval $SUB 2>>/tmp/mqtt-router.log | while IFS= read -r line; do
    topic="${line%% *}"; payload="${line#* }"; [ "$topic" = "$payload" ] && payload=""
    mode="$(current_mode)"
    dbg "MSG topic='$topic' mode='$mode' bytes=$(printf %s "$payload" | wc -c)"

    IFS='/' set -- $topic
    t1="$1"; t2="${2:-}"; t3="${3:-}"; t4="${4:-}"; t5="${5:-}"
    t6="${6:-}"; t7="${7:-}"; t8="${8:-}"; t9="${9:-}"; t10="${10:-}"

    prep_routes | while IFS='|' read -r filt url tmpl want require; do
      [ -z "$filt" ] && continue
      [ "$want" = "any" ] || [ "$want" = "$mode" ] || continue
      [ "$(mqtt_match "$filt" "$topic")" = "1" ] || continue
      require_ok "${require:-}" || continue

      qs="$tmpl"
      qs="${qs//\{mode\}/$(urlencode "$mode")}"
      qs="${qs//\{topic\}/$(urlencode "$topic")}"
      qs="${qs//\{payload\}/$(urlencode "$payload")}"
      qs="${qs//\{t1\}/$(urlencode "$t1")}"
      qs="${qs//\{t2\}/$(urlencode "$t2")}"
      qs="${qs//\{t3\}/$(urlencode "$t3")}"
      qs="${qs//\{t4\}/$(urlencode "$t4")}"
      qs="${qs//\{t5\}/$(urlencode "$t5")}"
      qs="${qs//\{t6\}/$(urlencode "$t6")}"
      qs="${qs//\{t7\}/$(urlencode "$t7")}"
      qs="${qs//\{t8\}/$(urlencode "$t8")}"
      qs="${qs//\{t9\}/$(urlencode "$t9")}"
      qs="${qs//\{t10\}/$(urlencode "$t10")}"
      qs="$(expand_json_tokens "$qs")"

      full="${url}?${qs}"
      dbg "CALL $full"
      uclient-fetch -T 7 -O - "$full" >/dev/null 2>&1 || wget -qO- "$full" >/dev/null 2>&1
      rc=$?
      log "MATCH topic=$topic mode=$mode url=$url qs=$qs rc=$rc"
      dbg "HTTP rc=$rc"
    done
  done

  log "subscriber ended; retrying in 2s"
  sleep 2
done
