# GL.iNet Presence‑Aware MQTT → HTTP Router

> **Purpose:** Tie mmWave presence sensors (MQTT telemetry) to Shelly/Tasmota relays (HTTP calls) with a lightweight router and a presence “home/away” gate on GL.iNet/OpenWrt.

---

## 🗺️ Overview

This stack turns selected MQTT messages into HTTP requests against a local CGI.  
A separate **allowed‑presence** service writes `home|away` to a mode file so your automations only fire when appropriate.

- Works on BusyBox/ash (GL.iNet / OpenWrt).
- Sed‑free, POSIX shell, resilient subscriber loop.
- JSON parsing via `jsonfilter`.
- MQTT via `mosquitto_sub`/`mosquitto_pub`.
- HTTP via `uclient-fetch` (or `wget` fallback).

---

## 📁 Files & Layout

```
/usr/bin/mqtt-router.sh             # MQTT→HTTP router (sed-free, POSIX)
/etc/init.d/mqtt-router             # procd service wrapper
/etc/mqtt-http-routes.conf          # routing table

/www/cgi-bin/index.cgi              # device control API (start/stop/status)
/www/cgi-bin/echo.cgi               # debug echo (writes /tmp/mqtt-echo.log)
/www/cgi-bin/strobe_burst_mqtt.sh   # worker used by index.cgi (start action)
/www/cgi-bin/stop_all.sh            # global stop fallback

/usr/bin/allowed-presence.sh        # presence daemon (computes home/away)
/etc/allowed-presence.conf          # presence config
/tmp/allowed-presence/mode          # current mode (home|away)
/tmp/allowed-presence/override      # manual override (home|away)

/etc/mqtt-auth.conf                 # optional MQTT creds (used by index.cgi)
/etc/index-devices.json             # optional UI/device list
/usr/bin/index-gen.sh               # optional URL/HTML generator

/tmp/mqtt-router.log                # router log (MATCH lines, subscriber state)
/tmp/mqtt-echo.log                  # echo.cgi captures querystrings
```

---

## 🚀 Quick Start

```sh
# 1) Enable & start service (make sure init script sets BROKER=192.168.87.1)
/etc/init.d/mqtt-router enable
/etc/init.d/mqtt-router restart

# 2) (Optional) Arm/disarm the system
echo away > /tmp/allowed-presence/override   # arm (enables 'away' routes)
# echo home > /tmp/allowed-presence/override # disarm

# 3) Test publish
mosquitto_pub -h 192.168.87.1 -t tele/mmwave1/SENSOR \
  -m '{"R24DVD1":{"Human":{"Presence":"Occupied"}}}'

# 4) Watch logs
tail -f /tmp/mqtt-router.log
```

> **Expected:** `/tmp/mqtt-router.log` shows `MATCH ... index.cgi ... rc=0` when a route fires.

---

## 🧠 Presence Mode

The router reads **home/away** from:
- `/tmp/allowed-presence/mode` — authoritative mode written by `allowed-presence.sh`
- `/tmp/allowed-presence/override` — optional manual override (`home` or `away`)

Presence is computed from ARP + RX/TX rates + DHCP leases across multiple WLANs.  
Allowed devices are determined by IP ranges (e.g., `192.168.8.30–49`) configured in `/etc/allowed-presence.conf`.

**Manual override (useful for tests):**
```sh
echo away > /tmp/allowed-presence/override    # arm
echo home > /tmp/allowed-presence/override    # disarm
```

---

## 🔧 The Router: `/usr/bin/mqtt-router.sh`

- Subscribes to `BROKER` and streams MQTT messages.
- Evaluates each message against routes in `/etc/mqtt-http-routes.conf`.
- On match, builds a querystring from a template and calls the target URL.
- Resilient: no `set -e`, loops/retries the MQTT subscribe on errors.
- Optional single‑instance lock (recommended).

**Environment variables**

| Var        | Meaning                               | Example             |
|------------|---------------------------------------|---------------------|
| `BROKER`   | MQTT broker host/IP                    | `192.168.87.1`      |
| `DEBUG`    | `1` to print verbose debug to stderr   | `1`                 |
| `MOSQ_USER`| Optional MQTT username                 | `mqttuser`          |
| `MOSQ_PASS`| Optional MQTT password                 | `mqttpass`          |

**Logs**
- `/tmp/mqtt-router.log` — service lifecycle, subscriber restarts, **MATCH** lines with `rc=`.

**Single‑instance lock (optional)**

```sh
# near the top of mqtt-router.sh
LOCKDIR="/var/run/mqtt-router.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  echo "$(date '+%F %T') already running; exiting" >> /tmp/mqtt-router.log
  exit 0
fi
trap 'rmdir "$LOCKDIR"' EXIT INT TERM
```

---

## 🧩 Routes: `/etc/mqtt-http-routes.conf`

**Format** (pipe‑delimited, one per line):

```
topic_filter | url | query_template | mode | require
```

**Columns**

- **topic_filter** — MQTT with `+` (one level) and `#` (rest).  
  e.g. `tele/mmwave1/SENSOR`, `tele/+/SENSOR`, `tele/#`
- **url** — HTTP endpoint (local CGI), e.g. `http://127.0.0.1/cgi-bin/index.cgi`
- **query_template** — tokens are URL‑encoded automatically:
  - `{mode}`, `{topic}`, `{payload}`
  - `{t1}`..`{t10}` — topic segments (`tele/mmwave1/SENSOR` → `t1=tele`, `t2=mmwave1`, `t3=SENSOR`)
  - `{json:.path}` — JSON extract via `jsonfilter` (safe expansion)
- **mode** — `any` | `home` | `away` (compared to `/tmp/allowed-presence/mode`)
- **require** — extra condition (optional):
  - `json_eq:.path,value`
  - `json_in:.path,val1|val2|...`
  - `payload_eq:RAWJSON`
  - `tN_eq:value` (guards a topic segment, e.g., `t2_eq:mmwave1`)

**Production example (literal topic; *Option A*)**

```text
# Start Shelly when Occupied while 'away'
tele/mmwave1/SENSOR|http://127.0.0.1/cgi-bin/index.cgi|api=run&action=start&device=shelly1pm-C82B961DD588&type=shelly&relay=0&duration=30&burst=2&gap=0.50&host=192.168.87.1&port=1883&mode={mode}|away|json_eq:.R24DVD1.Human.Presence,Occupied

# Stop when Unoccupied in ANY mode
tele/mmwave1/SENSOR|http://127.0.0.1/cgi-bin/index.cgi|api=run&action=stop&device=shelly1pm-C82B961DD588&type=shelly&relay=0&host=192.168.87.1&port=1883&mode={mode}|any|json_in:.R24DVD1.Human.Presence,Unoccupied|None|Empty
```

**Debug route (place first while testing):**

```text
tele/#|http://127.0.0.1/cgi-bin/echo.cgi|topic={topic}&t2={t2}&presence={json:.R24DVD1.Human.Presence}&mode={mode}|any|
```

---

## 🔌 Device API: `/www/cgi-bin/index.cgi`

**Run API**

```
/cgi-bin/index.cgi?api=run&action=start|stop&device=<name>[&type=shelly|tasmota][&relay=N][&duration=S][&burst=N][&gap=F][&host=IP][&port=1883][&debug=1]
```

- **Type defaults**
  - `shelly`: `relay=0`, `duration=30`, `burst=3`, `gap=0.30`
  - `tasmota`: `relay=2`, `duration=10`, `burst=1`, `gap=0.75`

**Stop fallback logic**
1. Per‑device stop (if supported)
2. Global stop via `stop_all.sh`
3. **Force OFF** via MQTT:
   - Shelly topics: `shellies/<device>/relay/<relay>/command` (and `<device>/relay/...` as fallback)
   - Tasmota topics: `cmnd/<device>/POWER` (or `POWER2`, `POWER3`, etc., by relay)

**Optional auth** for MQTT publish by `index.cgi`:
```
/etc/mqtt-auth.conf  # exports MQTT_USER, MQTT_PASS
```

**Status API**
```
/cgi-bin/index.cgi?api=status&device=<tasmota_topic>[&host=IP&port=1883]
```
Returns `online`, `activity`, `motion`, `presence`, etc. (via `mosquitto_sub` one‑shot reads).

---

## 🧪 Debugging

- Add the catch‑all echo route on top while diagnosing:
  ```text
  tele/#|http://127.0.0.1/cgi-bin/echo.cgi|topic={topic}&t2={t2}&presence={json:.R24DVD1.Human.Presence}&mode={mode}|any|
  ```
- Confirm service uses the right broker:
  ```sh
  grep -n 'subscribing:' /tmp/mqtt-router.log | tail -n1
  # should show: mosquitto_sub -h "192.168.87.1" -v -t "#"
  ```
- Validate JSON paths:
  ```sh
  echo '{"R24DVD1":{"Human":{"Presence":"Occupied"}}}' | jsonfilter -e '@.R24DVD1.Human.Presence'
  # -> Occupied
  ```
- Normalize routes file line endings and pipes:
  ```sh
  sed -i 's/\r$//' /etc/mqtt-http-routes.conf
  ```
- Watch live:
  ```sh
  tail -f /tmp/mqtt-router.log
  tail -f /tmp/mqtt-echo.log
  ```

---

## 🛡️ Security Notes

- Keep CGI endpoints LAN‑only (default on GL.iNet/OpenWrt).
- Use MQTT auth (set `MOSQ_USER`/`MOSQ_PASS` for the router; `/etc/mqtt-auth.conf` for CGI publish).
- Validate device names/relays if exposing more API surface.

---

## 🤖 Common Tasks (Cheat‑Sheet)

```sh
# Service control
/etc/init.d/mqtt-router {start|stop|restart|enable|disable}

# Foreground debug
DEBUG=1 BROKER=192.168.87.1 /usr/bin/mqtt-router.sh

# Arm/disarm
echo away > /tmp/allowed-presence/override
echo home > /tmp/allowed-presence/override

# Add routes (literal topic example)
cat >> /etc/mqtt-http-routes.conf <<'EOF'
tele/mmwave1/SENSOR|http://127.0.0.1/cgi-bin/index.cgi|api=run&action=start&device=shelly1pm-C82B961DD588&type=shelly&relay=0&duration=30&burst=2&gap=0.50&host=192.168.87.1&port=1883&mode={mode}|away|json_eq:.R24DVD1.Human.Presence,Occupied
tele/mmwave1/SENSOR|http://127.0.0.1/cgi-bin/index.cgi|api=run&action=stop&device=shelly1pm-C82B961DD588&type=shelly&relay=0&host=192.168.87.1&port=1883&mode={mode}|any|json_in:.R24DVD1.Human.Presence,Unoccupied|None|Empty
EOF
/etc/init.d/mqtt-router restart
```

---

## ℹ️ Notes

- Seeing 2–3 `sh /usr/bin/mqtt-router.sh` in `ps` is normal due to pipeline subshells.
- The router includes a resilient subscribe loop; if `mosquitto_sub` drops, it retries and logs `subscriber ended; retrying in 2s`.

---

## 📜 License / Author

You (and future you). This README documents the exact stack configured on your GL.iNet router.
