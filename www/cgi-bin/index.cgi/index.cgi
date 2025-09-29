#!/bin/ash
# /www/cgi-bin/index.cgi  — config-driven Shelly/Tasmota panel + APIs

# ---------- tiny helpers ----------
urldecode() { s="$(echo "$1" | sed 's/+/ /g; s/%/\\x/g')"; printf '%b' "$s"; }
jescape()   { echo "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
http_get()  { uclient-fetch -T 7 -O - "$1" 2>/dev/null; }

mqtt_pub() {
  # mqtt_pub host port topic payload [user] [pass]
  local H="$1" P="$2" T="$3" M="$4" U="$5" X="$6"
  local PUB="/usr/bin/mosquitto_pub"
  [ -x "$PUB" ] || return 127
  if [ -n "$U" ] && [ -n "$X" ]; then
    "$PUB" -h "$H" -p "$P" -u "$U" -P "$X" -t "$T" -m "$M"
  else
    "$PUB" -h "$H" -p "$P" -t "$T" -m "$M"
  fi
}

# Optional auth file: exports MQTT_USER/MQTT_PASS if you need auth
[ -f /etc/mqtt-auth.conf ] && . /etc/mqtt-auth.conf

CFG_JSON="/etc/index-devices.json"

# ---------- API: /cgi-bin/index.cgi?api=run&action=start|stop&device=<name>[&type=...][&debug=1] ----------
case "${QUERY_STRING:-}" in
  api=run*)
    ACTION=""; DEVICE=""; TYPE=""; DEBUG="0"
    RELAY=""; DURATION=""; BURST=""; GAP=""
    HOST="192.168.87.1"; PORT="1883"

    IFS='&'; set -- $QUERY_STRING; IFS=' '
    for kv in "$@"; do
      k="${kv%%=*}"; v="${kv#*=}"; v="$(urldecode "$v")"
      case "$k" in
        action) ACTION="$v" ;;
        device) DEVICE="$v" ;;
        type)   TYPE="$v" ;;
        relay)  RELAY="$v" ;;
        duration) DURATION="$v" ;;
        burst)  BURST="$v" ;;
        gap)    GAP="$v" ;;
        host)   HOST="$v" ;;
        port)   PORT="$v" ;;
        debug)  DEBUG="$v" ;;
      esac
    done

    # infer type from device if missing
    [ -z "$TYPE" ] && {
      case "$DEVICE" in
        shelly*|Shelly*)   TYPE="shelly" ;;
        tasmota*|Tasmota*) TYPE="tasmota" ;;
        *)                 TYPE="tasmota" ;;
      esac
    }

    # per-type defaults if not explicitly provided
    case "$TYPE" in
      shelly)
        [ -z "$RELAY" ]    && RELAY="0"
        [ -z "$DURATION" ] && DURATION="30"
        [ -z "$BURST" ]    && BURST="3"
        [ -z "$GAP" ]      && GAP="0.3"
      ;;
      tasmota|*)
        [ -z "$RELAY" ]    && RELAY="2"
        [ -z "$DURATION" ] && DURATION="10"
        [ -z "$BURST" ]    && BURST="1"
        [ -z "$GAP" ]      && GAP="0.75"
      ;;
    esac

    echo "Status: 200 OK"
    echo "Content-Type: application/json"
    echo ""

    if [ -z "$ACTION" ] || [ -z "$DEVICE" ]; then
      echo '{"ok":false,"error":"missing action or device"}'
      exit 0
    fi

    BASE="http://127.0.0.1/cgi-bin"

    if [ "$ACTION" = "start" ]; then
      URL="$BASE/strobe_burst_mqtt.sh?action=start&type=$TYPE&device=$DEVICE&relay=$RELAY&duration=$DURATION&burst=$BURST&gap=$GAP&host=$HOST&port=$PORT"
      OUT="$(http_get "$URL")"
      if [ "$DEBUG" = "1" ]; then
        printf '{"ok":true,"mode":"http","url":"%s","resp":%s}\n' "$(jescape "$URL")" "${OUT:-null}"
      else
        [ -n "$OUT" ] && echo "$OUT" || printf '{"ok":true,"action":"start","device":"%s"}\n' "$(jescape "$DEVICE")"
      fi
      exit 0
    fi

    if [ "$ACTION" = "stop" ]; then
      URL1="$BASE/strobe_burst_mqtt.sh?action=stop&type=$TYPE&device=$DEVICE"
      OUT="$(http_get "$URL1")"

      if [ -z "$OUT" ]; then
        URL2="$BASE/stop_all.sh?all=1&host=$HOST&port=$PORT"
        OUT="$(http_get "$URL2")"
      fi

      FORCE_JSON=""
      case "$TYPE" in
        shelly)
          T1="shellies/$DEVICE/relay/$RELAY/command"
          T2="$DEVICE/relay/$RELAY/command"
          mqtt_pub "$HOST" "$PORT" "$T1" "off" "$MQTT_USER" "$MQTT_PASS"
          RC=$?
          [ $RC -ne 0 ] && mqtt_pub "$HOST" "$PORT" "$T2" "off" "$MQTT_USER" "$MQTT_PASS" && RC=$?
          FORCE_JSON=$(printf '"forced_off":{"type":"shelly","topics":["%s","%s"],"rc":%d}' "$(jescape "$T1")" "$(jescape "$T2")" "$RC")
        ;;
        tasmota|*)
          case "$RELAY" in ""|"1") PWR="POWER" ;; *) PWR="POWER$RELAY" ;; esac
          TT="cmnd/$DEVICE/$PWR"
          mqtt_pub "$HOST" "$PORT" "$TT" "OFF" "$MQTT_USER" "$MQTT_PASS"
          RC=$?
          FORCE_JSON=$(printf '"forced_off":{"type":"tasmota","topic":"%s","rc":%d}' "$(jescape "$TT")" "$RC")
        ;;
      esac

      if [ "$DEBUG" = "1" ]; then
        printf '{"ok":true,"mode":"http+mq","url_primary":"%s","url_fallback":"%s","resp":%s,%s}\n' \
          "$(jescape "$URL1")" "$(jescape "$URL2")" "${OUT:-null}" "$FORCE_JSON"
      else
        [ -n "$OUT" ] && echo "$OUT" || printf '{"ok":true,"action":"stop","device":"%s",%s}\n' "$(jescape "$DEVICE")" "$FORCE_JSON"
      fi
      exit 0
    fi

    echo '{"ok":false,"error":"bad action"}'
    exit 0
  ;;
esac

# ---------- API: /cgi-bin/index.cgi?api=status&device=<tasmota_topic>[&host=...&port=...] ----------
case "${QUERY_STRING:-}" in
  api=status*)
    HOST="127.0.0.1"; PORT="1883"; DEVICE=""
    IFS='&'; set -- $QUERY_STRING; IFS=' '
    for kv in "$@"; do
      k="${kv%%=*}"; v="${kv#*=}"; v="$(urldecode "$v")"
      case "$k" in
        device) DEVICE="$v" ;;
        host)   HOST="$v" ;;
        port)   PORT="$v" ;;
      esac
    done
    [ -z "$DEVICE" ] && {
      echo "Status: 400 Bad Request"
      echo "Content-Type: application/json"; echo ""
      echo '{"error":"missing device"}'
      exit 0
    }

    SUB="/usr/bin/mosquitto_sub"
    [ ! -x "$SUB" ] && {
      echo "Status: 500 Internal Server Error"
      echo "Content-Type: application/json"; echo ""
      echo '{"error":"mosquitto_sub not installed"}'
      exit 0
    }

    LWT="$($SUB -h "$HOST" -p "$PORT" -t "tele/$DEVICE/LWT" -C 1 -W 1 2>/dev/null)"
    [ -z "$LWT" ] && LWT="unknown"
    ONLINE=false; [ "$LWT" = "Online" ] && ONLINE=true

    PAYLOAD="$($SUB -h "$HOST" -p "$PORT" -t "tele/$DEVICE/SENSOR" -C 1 -W 1 2>/dev/null)"

    if command -v jsonfilter >/dev/null 2>&1; then
      ACT="$(echo "$PAYLOAD" | jsonfilter -l1 -e '@["R24DVD1"]["Human"]["Activity"]' 2>/dev/null)"
      MOT="$(echo "$PAYLOAD" | jsonfilter -l1 -e '@["R24DVD1"]["Human"]["Motion"]'   2>/dev/null)"
      PRE="$(echo "$PAYLOAD" | jsonfilter -l1 -e '@["R24DVD1"]["Human"]["Presence"]' 2>/dev/null)"
    else
      ACT="$(echo "$PAYLOAD" | grep -o '"Activity":"[^"]*"' | head -n1 | cut -d: -f2 | tr -d '"')"
      MOT="$(echo "$PAYLOAD" | grep -o '"Motion":"[^"]*"'   | head -n1 | cut -d: -f2 | tr -d '"')"
      PRE="$(echo "$PAYLOAD" | grep -o '"Presence":"[^"]*"' | head -n1 | cut -d: -f2 | tr -d '"')"
    fi

    STATE="$PRE"; [ -z "$STATE" ] && STATE="—"

    echo "Status: 200 OK"
    echo "Content-Type: application/json"
    echo ""
    echo "{\"device\":\"$(jescape "$DEVICE")\",\"online\":$ONLINE,\"lwt\":\"$(jescape "$LWT")\",\"activity\":\"$(jescape "$ACT")\",\"motion\":\"$(jescape "$MOT")\",\"presence\":\"$(jescape "$PRE")\",\"state\":\"$(jescape "$STATE")\"}"
    exit 0
  ;;
esac

# ---------- CONFIG-DRIVEN HTML ----------
# We use jshn to parse /etc/index-devices.json and render tiles.
if ! [ -r "$CFG_JSON" ]; then
  echo "Status: 500 Internal Server Error"
  echo "Content-Type: text/plain"; echo ""
  echo "Missing $CFG_JSON"
  exit 0
fi

if ! . /usr/share/libubox/jshn.sh 2>/dev/null; then
  echo "Status: 500 Internal Server Error"
  echo "Content-Type: text/plain"; echo ""
  echo "jshn not available (libubox). Install or include it."
  exit 0
fi

json_cleanup
json_load_file "$CFG_JSON" || json_init

# MQTT defaults
MQTT_HOST_DEF="192.168.87.1"
MQTT_PORT_DEF="1883"
if json_select mqtt 2>/dev/null; then
  json_get_var MQTT_HOST_DEF host
  json_get_var MQTT_PORT_DEF port
  [ -z "$MQTT_HOST_DEF" ] && MQTT_HOST_DEF="192.168.87.1"
  [ -z "$MQTT_PORT_DEF" ] && MQTT_PORT_DEF="1883"
  json_select ..
fi

echo "Status: 200 OK"
echo "Content-Type: text/html"
echo ""

cat <<'HTML_HEAD'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Shelly / Tasmota Control Panel</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root{--bg:#0b0f14;--card:#131a22;--fg:#e8eef5;--accent:#4ea1ff;--accent2:#7cd992;--danger:#ff5a5a;--muted:#98a2b3}
  html,body{margin:0;background:var(--bg);color:var(--fg);font-family:system-ui,-apple-system,Segoe UI,Roboto,Ubuntu,"Helvetica Neue",Arial}
  .wrap{max-width:1000px;margin:0 auto;padding:20px}
  h1{margin:0 0 12px;font-size:clamp(20px,4vw,28px);font-weight:800}
  p{opacity:.9;margin:0 0 16px}
  .grid{display:grid;gap:16px;grid-template-columns:repeat(auto-fit,minmax(240px,1fr))}
  .tile{background:var(--card);border:2px solid rgba(255,255,255,.06);border-radius:22px;padding:16px;box-shadow:0 6px 18px rgba(0,0,0,.25)}
  .head{display:flex;justify-content:space-between;align-items:center;gap:10px}
  .label{font-weight:800;font-size:clamp(16px,3.5vw,20px)}
  .status{font-size:.9em;opacity:.9;margin-top:6px}
  .ok{color:#b8f397}.err{color:#ffb3b3}.muted{color:var(--muted)}
  .row{display:flex;gap:10px;flex-wrap:wrap;margin-top:12px}
  .btn{appearance:none;border:0;border-radius:14px;padding:12px 14px;font-weight:800;cursor:pointer}
  .start{background:linear-gradient(180deg,color-mix(in oklab,var(--accent),#000 35%),var(--card));color:var(--fg)}
  .stop{background:linear-gradient(180deg,color-mix(in oklab,var(--danger),#000 35%),var(--card));color:var(--fg)}
  .gear{background:#0c1219;color:var(--fg)}
  .btn.state{min-width:160px;background:#0c1219;border:1px solid #1b2330}
  .btn.state.active{background:linear-gradient(180deg,color-mix(in oklab,var(--accent2),#000 35%),var(--card))}
  .btn.state.none{opacity:.85}
  .badge{background:#0c1219;border:1px solid #1b2330;border-radius:10px;padding:4px 8px;font-weight:700}
  .badge.on{border-color:#355f3b;color:#b8f397}
  .badge.off{border-color:#5f3535;color:#ffb3b3}
  .settings{display:none;margin-top:10px;border-top:1px solid #1b2330;padding-top:10px}
  .settings.open{display:block}
  .field{display:grid;grid-template-columns:1fr auto;gap:8px;align-items:center;margin-top:8px}
  input[type=range]{width:100%}
  .accent{background:linear-gradient(180deg,color-mix(in oklab,var(--accent),#000 35%),var(--card))}
  .accent2{background:linear-gradient(180deg,color-mix(in oklab,var(--accent2),#000 35%),var(--card))}
</style>
</head>
<body>
<div class="wrap">
  <h1>Shelly / Tasmota Control Panel</h1>
  <p>Tiles are now generated from <code>/etc/index-devices.json</code>. Use ⚙️ to adjust Burst/Gap; click Start to run.</p>
  <div class="grid">
HTML_HEAD

# ---------- dynamic tiles from JSON ----------
render_radar_tile() {
  # $1=label $2=device $3=host $4=port
  cat <<EOF
    <div class="tile accent" data-type="radar" data-device="$(jescape "$2")" data-host="$3" data-port="$4">
      <div class="head">
        <div class="label">$(jescape "$1")</div>
        <span class="badge badge-online">checking…</span>
      </div>
      <div class="status muted">Motion/Activity: <span class="motion">—</span></div>
      <div class="row"><button class="btn state none" disabled>State: <span class="state-txt">—</span></button></div>
    </div>
EOF
}

render_relay_tile() {
  # $1=type $2=label $3=device $4=relay $5=duration $6=burst $7=gap $8=host $9=port
  local klass="accent2"
  [ "$1" = "tasmota" ] && klass="accent"
  cat <<EOF
    <div class="tile $klass" data-type="$1" data-device="$(jescape "$3")" data-relay="$4" data-duration="$5" data-host="$8" data-port="$9">
      <div class="head">
        <div class="label">$(jescape "$2")</div>
        <button class="btn gear toggle">⚙️ Settings</button>
      </div>
      <div class="status muted">relay $4 • default Burst=$6 • Gap=$(printf '%0.2f' "$7") • ${5}s</div>

      <div class="settings">
        <div class="field">
          <label>Burst (1–9)</label>
          <span class="badge burst-val">$6</span>
          <input class="burst" type="range" min="1" max="9" step="1" value="$6">
        </div>
        <div class="field">
          <label>Gap (0.20–1.50)</label>
          <span class="badge gap-val">$(printf '%0.2f' "$7")</span>
          <input class="gap" type="range" min="0.2" max="1.5" step="0.05" value="$7">
        </div>
      </div>

      <div class="row">
        <button class="btn start do-start">Start</button>
      </div>
    </div>
EOF
}

render_stopall_tile() {
  # $1=label $2=host $3=port
  cat <<EOF
    <div class="tile">
      <div class="head"><div class="label">$(jescape "$1")</div></div>
      <div class="status muted">Global stop • kill workers • force OFF</div>
      <div class="row">
        <button class="btn stop do-stopall" data-url="/cgi-bin/stop_all.sh?all=1&host=$2&port=$3">Stop All</button>
      </div>
    </div>
EOF
}

# iterate tiles
if json_select tiles 2>/dev/null; then
  json_get_keys TIDX
  for i in $TIDX; do
    json_select "$i"
    json_get_var TYPE type
    json_get_var DEVICE device
    json_get_var LABEL label
    # mqtt per-tile or defaults
    HOST="$MQTT_HOST_DEF"; PORT="$MQTT_PORT_DEF"
    json_get_var tmp host && [ -n "$tmp" ] && HOST="$tmp"
    json_get_var tmp port && [ -n "$tmp" ] && PORT="$tmp"

    case "$TYPE" in
      radar|mmwave)
        [ -z "$LABEL" ] && LABEL="$DEVICE"
        render_radar_tile "$LABEL" "$DEVICE" "$HOST" "$PORT"
      ;;
      shelly|tasmota)
        json_get_var RELAY relay;      [ -z "$RELAY" ] && RELAY="0"
        json_get_var DURATION duration;[ -z "$DURATION" ] && DURATION="10"
        json_get_var BURST burst;      [ -z "$BURST" ] && BURST="2"
        json_get_var GAP gap;          [ -z "$GAP" ] && GAP="0.50"
        [ -z "$LABEL" ] && LABEL="$(echo "$TYPE" | tr a-z A-Z) Strobe"
        render_relay_tile "$TYPE" "$LABEL" "$DEVICE" "$RELAY" "$DURATION" "$BURST" "$GAP" "$HOST" "$PORT"
      ;;
      stopall)
        [ -z "$LABEL" ] && LABEL="STOP — All Devices"
        render_stopall_tile "$LABEL" "$HOST" "$PORT"
      ;;
    esac
    json_select ..
  done
  json_select ..
fi

cat <<'HTML_FOOT'
  </div>
</div>

<script>
(function(){
  function fmt(n){ return (Math.round(Number(n)*100)/100).toFixed(2); }

  document.querySelectorAll('.tile .toggle').forEach(btn=>{
    btn.addEventListener('click', ()=>{
      const s = btn.closest('.tile').querySelector('.settings');
      s.classList.toggle('open');
    });
  });

  document.querySelectorAll('.tile').forEach(tile=>{
    const burst = tile.querySelector('.burst');
    const gap   = tile.querySelector('.gap');
    const bval  = tile.querySelector('.burst-val');
    const gval  = tile.querySelector('.gap-val');
    if(burst && bval){ burst.addEventListener('input', ()=>{ bval.textContent = burst.value; }); }
    if(gap && gval){ gap.addEventListener('input',  ()=>{ gval.textContent  = fmt(gap.value); }); }
  });

  async function startTile(tile){
    const status = tile.querySelector('.status');
    const startBtn = tile.querySelector('.do-start');
    const type  = tile.dataset.type;
    const dev   = tile.dataset.device;
    const relay = tile.dataset.relay || '0';
    const dur   = tile.dataset.duration || '10';
    const host  = tile.dataset.host || '127.0.0.1';
    const port  = tile.dataset.port || '1883';
    const burst = tile.querySelector('.burst')?.value || '2';
    const gap   = tile.querySelector('.gap')?.value || '0.5';
    const url = `/cgi-bin/strobe_burst_mqtt.sh?action=start&type=${encodeURIComponent(type)}&device=${encodeURIComponent(dev)}&relay=${relay}&duration=${dur}&burst=${burst}&gap=${gap}&host=${host}&port=${port}`;
    startBtn?.setAttribute('aria-busy','true');
    status && (status.textContent='Starting…', status.className='status muted');
    try{
      const res = await fetch(url,{headers:{'Accept':'application/json'}});
      const ct = res.headers.get('content-type')||'';
      const data = ct.includes('application/json') ? await res.json() : { ok: res.ok };
      if(res.ok && (data.ok===true || data.started)){
        const msg = data.pid ? `Started (pid ${data.pid})` : 'Started';
        status && (status.textContent = `${msg} • Burst=${burst} Gap=${fmt(gap)} • ${dur}s`, status.className='status ok');
      } else {
        status && (status.textContent = `Error: HTTP ${res.status}${data.error?` — ${data.error}`:''}`, status.className='status err');
      }
    }catch(e){
      status && (status.textContent = `Error: ${e}`, status.className='status err');
    }finally{
      startBtn?.removeAttribute('aria-busy');
    }
  }
  document.querySelectorAll('.do-start').forEach(btn=>{
    btn.addEventListener('click', ()=> startTile(btn.closest('.tile')));
  });

  document.querySelectorAll('.do-stopall').forEach(btn=>{
    btn.addEventListener('click', async ()=>{
      const tile = btn.closest('.tile');
      const status = tile.querySelector('.status');
      const url = btn.dataset.url;
      btn.setAttribute('aria-busy','true');
      status && (status.textContent='Stopping…', status.className='status muted');
      try{
        const res = await fetch(url, {headers:{'Accept':'application/json'}});
        const ct = res.headers.get('content-type')||'';
        const data = ct.includes('application/json') ? await res.json() : { ok: res.ok };
        if(res.ok && data.ok===true){
          status && (status.textContent = `Stopped All • S=${data.shelly_processed||0} T=${data.tasmota_processed||0}`, status.className='status ok');
        }else{
          status && (status.textContent = `Error: HTTP ${res.status}${data.error?` — ${data.error}`:''}`, status.className='status err');
        }
      }catch(e){
        status && (status.textContent = `Error: ${e}`, status.className='status err');
      }finally{
        btn.removeAttribute('aria-busy');
      }
    });
  });

  async function pollRadar(tile){
    const dev  = tile.dataset.device;
    const host = tile.dataset.host || '127.0.0.1';
    const port = tile.dataset.port || '1883';
    const url  = `/cgi-bin/index.cgi?api=status&device=${encodeURIComponent(dev)}&host=${encodeURIComponent(host)}&port=${encodeURIComponent(port)}`;

    const online = tile.querySelector('.badge-online');
    const motion = tile.querySelector('.motion');
    const btn    = tile.querySelector('.btn.state');
    const btnTxt = tile.querySelector('.state-txt');

    try{
      const res = await fetch(url, {cache:'no-store'});
      if(!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();

      const on = !!data.online;
      if(online){
        online.textContent = on ? 'Online' : 'Offline';
        online.classList.remove('on','off');
        online.classList.add(on ? 'on' : 'off');
      }

      const presence = data.presence || '—';
      const motionText = data.motion || data.activity || '—';
      motion && (motion.textContent = motionText);

      if (btn && btnTxt) {
        btnTxt.textContent = presence;
        btn.classList.remove('active','none');
        const isActive = (presence === 'Occupied');
        btn.classList.add(isActive ? 'active' : 'none');
      }
    }catch(e){
      if(online){ online.textContent='error'; online.classList.remove('on'); online.classList.add('off'); }
      if(btnTxt){ btnTxt.textContent='—'; btn?.classList.remove('active'); btn?.classList.add('none'); }
      if(motion){ motion.textContent='—'; }
    }
  }

  const radars = Array.from(document.querySelectorAll('.tile[data-type="radar"]'));
  radars.forEach(tile=>{ pollRadar(tile); setInterval(()=>pollRadar(tile), 5000); });
})();
</script>
</body>
</html>
HTML_FOOT
