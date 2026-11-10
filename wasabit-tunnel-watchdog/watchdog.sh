#!/bin/sh
# Tunnel Watchdog for umbrelOS
# Restarts the Cloudflare Tunnel connector when the tunnel isn't registered
# and the internet is already up (typical case: it started before the network
# after a power outage).

TARGET="${TARGET_CONTAINER:-cloudflared_connector_1}"
PORT="${METRICS_PORT:-40901}"
INTERVAL="${CHECK_INTERVAL:-180}"
GRACE="${STARTUP_GRACE:-180}"
MAX_FAILS="${FAILS_BEFORE_RESTART:-2}"
DNS_PROBE="${DNS_PROBE:-region1.v2.argotunnel.com}"

DATA="${DATA_DIR:-/data}"
WWW="$DATA/www"
LOG="$DATA/watchdog.log"
COUNT_FILE="$DATA/restarts"

mkdir -p "$WWW"
[ -f "$COUNT_FILE" ] || echo 0 > "$COUNT_FILE"

now() { date '+%Y-%m-%d %H:%M:%S'; }

log() {
  line="$(now) $*"
  echo "$line"
  echo "$line" >> "$LOG"
  # Keep only the last 200 lines
  tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
}

# Writes the status page: $1 = class (ok|warn|bad), $2 = text
page() {
  restarts=$(cat "$COUNT_FILE")
  {
    cat <<EOF
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="30">
<title>Tunnel Watchdog</title>
<style>
 body{font-family:system-ui,sans-serif;max-width:720px;margin:2rem auto;padding:0 1rem;background:#111;color:#eee}
 .st{padding:1rem 1.25rem;border-radius:10px;font-size:1.15rem;margin:1rem 0}
 .ok{background:#123d23}.warn{background:#4a3a10}.bad{background:#4a1515}
 dl{display:grid;grid-template-columns:auto 1fr;gap:.3rem 1rem;color:#bbb}
 pre{background:#1c1c1c;padding:1rem;border-radius:8px;overflow-x:auto;font-size:.85rem}
</style></head><body>
<h1>Tunnel Watchdog</h1>
<div class="st $1">$2</div>
<dl>
 <dt>Last check</dt><dd>$(now)</dd>
 <dt>Watched container</dt><dd>$TARGET</dd>
 <dt>Restarts performed</dt><dd>$restarts</dd>
 <dt>Check interval</dt><dd>${INTERVAL}s</dd>
</dl>
<h2>Log</h2>
<pre>
EOF
    # Most recent first
    sed '1!G;h;$!d' "$LOG" 2>/dev/null | head -n 50
    echo "</pre></body></html>"
  } > "$WWW/index.html.tmp" && mv "$WWW/index.html.tmp" "$WWW/index.html"
}

tunnel_ready() {
  ips=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$TARGET" 2>/dev/null)
  for ip in $ips; do
    wget -q -T 5 -O /dev/null "http://$ip:$PORT/ready" 2>/dev/null && return 0
  done
  return 1
}

# DNS is what failed after the outage, so that's what we check.
internet_ok() {
  nslookup "$DNS_PROBE" >/dev/null 2>&1 && return 0
  ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1
}

log "Starting. Watching $TARGET every ${INTERVAL}s (initial wait ${GRACE}s)."
page warn "Starting up, first check in ${GRACE}s…"
sleep "$GRACE"

fails=0
while true; do
  running=$(docker inspect -f '{{.State.Running}}' "$TARGET" 2>/dev/null)

  if [ "$running" != "true" ]; then
    # The app is stopped or uninstalled: we don't start it ourselves.
    fails=0
    page warn "Container $TARGET is not running (app stopped). Doing nothing."
  elif tunnel_ready; then
    [ "$fails" -gt 0 ] && log "Tunnel recovered."
    fails=0
    page ok "Tunnel connected ✔"
  elif ! internet_ok; then
    page bad "Tunnel down, but there's no internet/DNS yet. Waiting."
    [ "$fails" -eq 0 ] && log "Tunnel down and no internet; waiting for the network to come back."
    fails=1
  else
    fails=$((fails + 1))
    if [ "$fails" -ge "$MAX_FAILS" ]; then
      log "Tunnel down with internet OK ($fails checks). Restarting $TARGET."
      if docker restart -t 20 "$TARGET" >/dev/null 2>&1; then
        echo $(( $(cat "$COUNT_FILE") + 1 )) > "$COUNT_FILE"
        page warn "Restarted $TARGET, verifying in ${GRACE}s…"
      else
        log "ERROR: could not restart $TARGET."
        page bad "Tunnel down and restarting $TARGET failed."
      fi
      fails=0
      sleep "$GRACE"
      continue
    else
      log "Tunnel not responding with internet OK (failure $fails of $MAX_FAILS)."
      page bad "Tunnel not responding (failure $fails of $MAX_FAILS). Will restart if it persists."
    fi
  fi

  sleep "$INTERVAL"
done
