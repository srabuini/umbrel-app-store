# Wasabit Labs — Umbrel Community App Store

## Tunnel Watchdog

Watches umbrelOS's **Cloudflare Tunnel** app. When power comes back and
cloudflared starts before the internet is up, the DNS lookup for
`_v2-origintunneld._tcp.argotunnel.com` fails and the tunnel stops. The
container stays alive, so Docker never restarts it. This app detects that and
restarts the connector once the network is back.

How it decides:

1. Every 3 minutes it queries `http://<connector-ip>:40901/ready`, which returns
   200 only when at least one connection to Cloudflare is registered.
2. If that fails, it checks whether DNS/internet works. While it doesn't, it waits.
3. With internet OK and **2 consecutive failures**, it runs `docker restart cloudflared_connector_1`.
4. If the Cloudflare Tunnel app is stopped, it does nothing.

Opening the app from the dashboard shows the current status, the restart count and the log.

### Images pulled on install

- `docker:27-cli`: Docker client on Alpine, for the watchdog.
- `busybox:1.36`: minimal web server for the status page.

### Installation

1. Replace `YOUR_USERNAME` in `wasabit-tunnel-watchdog/umbrel-app.yml` with your GitHub username.
2. Push this directory to a **public** GitHub repo, for example `umbrel-app-store`.
3. In Umbrel: **App Store → ⋯ (top right) → Community App Stores**,
   paste the repo URL and add it.
4. Open the "Wasabit Labs" store and install **Tunnel Watchdog**.

### Configuration

Set these in `docker-compose.yml`, in the `environment` block of the `watchdog` service:

| Variable | Default | What it does |
|---|---|---|
| `TARGET_CONTAINER` | `cloudflared_connector_1` | Container to watch (check it with `docker ps`) |
| `CHECK_INTERVAL` | `180` | Seconds between checks |
| `STARTUP_GRACE` | `180` | Wait at startup and after each restart |
| `FAILS_BEFORE_RESTART` | `2` | Consecutive failures (with internet) before restarting |
| `DNS_PROBE` | `region1.v2.argotunnel.com` | Hostname resolved to tell whether the network is up |
| `TZ` | `ART3` | Timezone for log timestamps (POSIX format, `ART3` = UTC-3) |

### Testing

Unplug the Umbrel's network cable, restart the Cloudflare Tunnel app, and plug
the cable back in. Within about 6 to 9 minutes the status page should show a
restart and "Tunnel connected".

You can also follow the logs with `docker logs -f wasabit-tunnel-watchdog_watchdog_1`.
