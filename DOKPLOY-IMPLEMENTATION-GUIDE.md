# Dokploy Implementation Guide

Step-by-step instructions to deploy the Jellyfin + *arr media stack on [Dokploy](https://dokploy.com). Complete each phase in order.

For architecture overview, security notes, and troubleshooting, see [README.md](README.md).

This stack is deployed by **home-svr Dokploy** (`https://dokploy.mattapps.org`), not the mattapps primary node. Traefik domains are **not** used for this stack. Git source: GitHub App **Dokploy-Home-svr** → `rdeveloper1925/jellyfin_stack` @ `master`, compose `./docker-compose.yml`.

---

## Before you start

### Checklist

- [ ] home-svr Dokploy installed (`https://dokploy.mattapps.org`) with GitHub App **Dokploy-Home-svr**
- [ ] [Tailscale](https://tailscale.com/) running on the deploy host
- [ ] [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) installed on the deploy host
- [ ] A domain in Cloudflare (`mattapps.org` — for the Jellyfin tunnel only)
- [ ] PIA VPN subscription with username and password
- [ ] Enough disk space on a **single filesystem** for media + downloads (hardlinks require this)

### What you will configure

| Phase | Time estimate |
|-------|---------------|
| 1. Prepare the deploy server | 15 min |
| 2. Configure environment | 10 min |
| 3. Create Dokploy project | 10 min |
| 4. First deploy | 5–15 min |
| 5. Cloudflare Tunnel (Jellyfin) | 10 min |
| 6. Verify VPN | 5 min |
| 7. Configure applications | 30–60 min |

---

## Phase 1: Prepare the deploy server

### Step 1.1 — Choose storage paths

Pick two absolute paths on the deploy host:

| Variable | Purpose | Example |
|----------|---------|---------|
| `MEDIA_ROOT` | Downloads + library | `/home/matt/PLEX/media` |
| `CONFIG_ROOT` | App settings and databases | `/home/matt/PLEX/config` |

Both paths must be on the host where containers run.

### Step 1.2 — Get your user ID

SSH into the deploy server and run:

```bash
id your_user
```

Note the `uid` and `gid` (usually `1000` / `1000`). You will use these as `PUID` and `PGID`.

### Step 1.3 — Create directories

```bash
export MEDIA_ROOT=/home/matt/PLEX/media    # change to your path
export CONFIG_ROOT=/home/matt/PLEX/config  # change to your path
export PUID=1000                           # change to your uid
export PGID=1000                           # change to your gid

mkdir -p ${MEDIA_ROOT}/torrents/{movies,tv,incomplete}
mkdir -p ${MEDIA_ROOT}/media/{movies,tv}
mkdir -p ${CONFIG_ROOT}/{jellyfin,sonarr,radarr,prowlarr,seerr,qbittorrent,gluetun}

chown -R ${PUID}:${PGID} ${MEDIA_ROOT} ${CONFIG_ROOT}
```

### Step 1.4 — Get Tailscale IP

On the deploy host:

```bash
tailscale ip -4
```

Save this as `BIND_IP` — admin UIs (except Jellyfin) will listen only on this address. Use your Tailscale IP (`tailscale ip -4`) or LAN IP depending on how you reach the deploy host privately.

### Step 1.5 — Confirm VPN support

Gluetun needs TUN device access on the host:

```bash
ls -l /dev/net/tun
```

If the file exists, you are good. Docker must run with privileges that allow `NET_ADMIN`.

### Step 1.6 — Sidecar watchdog and Docker package hold

After a Docker daemon restart, qBittorrent/Prowlarr/FlareSolverr can stay exited (`cannot join network namespace of a non running container`). Install the repo watchdog (systemd oneshot `After=docker.service` + 2-minute timer) and hold Docker packages so `apt upgrade` cannot bounce the daemon:

```bash
sudo install -m 755 scripts/sidecar-watchdog.sh /usr/local/sbin/jellyfin-stack-sidecar-watchdog.sh
sudo install -m 644 scripts/jellyfin-stack-sidecar-watchdog.service /etc/systemd/system/
sudo install -m 644 scripts/jellyfin-stack-sidecar-watchdog.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now jellyfin-stack-sidecar-watchdog.timer
sudo apt-mark hold docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-ce-rootless-extras docker-compose-plugin
```

Remove any leftover `*/10 * * * * .../retry-pia-portforward.sh` cron. The watchdog is log-only when 8080/9696/8191 are listening.

---

## Phase 2: Configure environment

### Step 2.1 — Copy the template

On your local machine or server, in this project directory:

```bash
cp .env.example .env
```

### Step 2.2 — Fill in every value

Edit `.env`:

```bash
# --- Identity / paths ---
PUID=1000
PGID=1000
TZ=America/New_York
MEDIA_ROOT=/home/matt/PLEX/media
CONFIG_ROOT=/home/matt/PLEX/config

# --- PIA VPN (Gluetun) ---
OPENVPN_USER=p1234567
OPENVPN_PASSWORD=your_pia_password
SERVER_REGIONS=Algeria,India,China
VPN_PORT_FORWARDING=on

# --- Network / access ---
BIND_IP=100.x.x.x
LAN_SUBNET=192.168.2.0/24,100.64.0.0/10

# --- Jellyfin ---
JELLYFIN_PUBLISHED_SERVER_URL=https://movies.mattapps.org

# --- qBittorrent ---
WEBUI_PORT=8080

# --- Prowlarr ---
PROWLARR_PORT=9696
```

| Variable | What to enter |
|----------|---------------|
| `MEDIA_ROOT` / `CONFIG_ROOT` | Paths from Step 1.1 |
| `PUID` / `PGID` | Values from Step 1.2 |
| `TZ` | Your [timezone](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones) |
| `BIND_IP` | Tailscale IP from Step 1.4 |
| `OPENVPN_USER` / `OPENVPN_PASSWORD` | PIA credentials |
| `SERVER_REGIONS` | Asia-focused PIA regions (`Algeria,India,China`); compose sets `PORT_FORWARD_ONLY=on`. Do not paste the full PIA region list. |
| `LAN_SUBNET` | Your LAN CIDR **and** `100.64.0.0/10` (Tailscale), comma-separated. Do not add `10.0.0.0/8`. Docker overlay/bridge allowlists are hardcoded in compose. Do not set `DOCKER_SUBNET`. |
| `JELLYFIN_PUBLISHED_SERVER_URL` | `https://movies.mattapps.org` (Cloudflare Tunnel public hostname) |
| `WEBUI_PORT` | Leave as `8080` unless you have a conflict |
| `PROWLARR_PORT` | Leave as `9696` unless you have a conflict |

> **Do not commit `.env`** — it contains secrets and is gitignored.

---

## Phase 3: Create the Dokploy project

### Step 3.1 — Create a project

1. Log in to **home-svr Dokploy** (`https://dokploy.mattapps.org`).
2. Go to **Projects** → **Create Project**.
3. Name it (e.g. `media-stack` / **Jellyfin Stack**).

### Step 3.2 — Add a Docker Compose service

1. Inside the project, click **Create Service** → **Docker Compose**.
2. Provider: GitHub App **Dokploy-Home-svr**.
3. Repository: `rdeveloper1925/jellyfin_stack`, branch `master`, compose path `./docker-compose.yml`.
4. Leave **Auto Deploy** off unless you already rely on it.

   If the App is installed but this service still shows an empty GitHub account, select **Dokploy-Home-svr**, then the `jellyfin_stack` repo. Grant the App access to `rdeveloper1925/jellyfin_stack` in GitHub if the repo is missing from the dropdown.

### Step 3.3 — Set environment variables in Dokploy

1. Open the service → **Environment** tab.
2. Paste **every** variable from your `.env` file (same keys and values).
3. Save.

Dokploy injects these into Compose substitution (`${VAR}`). VPN credentials are only referenced in the Gluetun service block.

### Step 3.4 — Verify compose settings

- Compose file path: `./docker-compose.yml`
- Deploy from the **full Git repository** (`rdeveloper1925/jellyfin_stack`) so `qbittorrent-init/` is available on the deploy host
- After checkout, `chown -R root:root qbittorrent-init && chmod 750 qbittorrent-init/*.sh` (linuxserver `/custom-cont-init.d` warns if not root-owned, and skips mode `640` as not executable). The sidecar watchdog re-applies this when it runs as root.
- Do **not** add `container_name` to any service (breaks Dokploy logs/metrics)
- The stack expects external network `dokploy-network` (Dokploy creates this on the deploy host)
- **Do not assign Domains** in Dokploy for any service in this stack
- Gluetun health is set in compose (`HEALTH_TARGET_ADDRESSES=1.1.1.1:443,8.8.8.8:443`, `start_period: 90s`). Do not use github.com/cloudflare.com health targets.

---

## Phase 4: First deploy

### Step 4.1 — Deploy

1. Click **Deploy** in Dokploy.
2. Watch the build/deploy logs.
3. Wait until all containers are running:
   - `gluetun`
   - `qbittorrent`
   - `jellyfin`
   - `sonarr`
   - `radarr`
   - `prowlarr`
   - `flaresolverr`
   - `seerr`

### Step 4.2 — Confirm Gluetun is healthy

On the deploy host:

```bash
docker ps --filter "name=gluetun"
```

Status should be **healthy**.

### Step 4.3 — Confirm Tailscale port bindings

On the deploy host:

```bash
ss -tlnp | grep 100.
```

You should see ports **5055**, **8989**, **7878**, **9696**, and **8080** bound to your `BIND_IP`. Jellyfin is **not** on `BIND_IP` — it listens on `127.0.0.1:8096` only.

---

## Phase 5: Cloudflare Tunnel (Jellyfin only)

Jellyfin public access uses **cloudflared on the deploy host** — not a Docker container. The stack publishes Jellyfin on `127.0.0.1:8096` for the host tunnel to forward.

### Step 5.1 — Confirm host cloudflared

On the deploy host:

```bash
systemctl status cloudflared
```

If not installed, follow [Cloudflare's Linux install guide](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/).

Ensure the unit uses a generous start timeout (home-svr uses `TimeoutStartSec=60` in `/etc/systemd/system/cloudflared.service`). The stock 15s timeout can fail when the tunnel is slow to come up after host routing issues.

**Gluetun must stay on `dokploy-network` with port mappings** — do not use `network_mode: host` for Gluetun; host-mode VPN routes break cloudflared.

### Step 5.2 — Configure public hostname

In **Cloudflare Zero Trust** → your tunnel → **Public Hostname**:

| Field | Value |
|-------|-------|
| Hostname | `movies.mattapps.org` |
| Service type | HTTP |
| URL | `http://127.0.0.1:8096` (**HTTP only** — not `https://`) |

> Use `127.0.0.1`, not `jellyfin` — the Docker hostname is not resolvable from the host.

### Step 5.3 — Verify Jellyfin is reachable locally

On the deploy host:

```bash
ss -tlnp | grep 8096
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8096
```

Should show Jellyfin listening on `127.0.0.1:8096` and return `200` or `302`.

### Step 5.4 — Configure Jellyfin

1. Open **https://movies.mattapps.org**.
2. Complete the setup wizard (create a local admin account).
3. **Dashboard → Networking** → set **Published Server URL** to `https://movies.mattapps.org` (must match `JELLYFIN_PUBLISHED_SERVER_URL`).

---

## Phase 6: Verify VPN

### Step 6.1 — Check VPN IP

```bash
docker exec $(docker ps -q --filter "name=gluetun") wget -qO- https://api.ipify.org
```

The returned IP should **not** match your home/server public IP.

### Step 6.2 — Confirm port forwarding (optional)

```bash
docker logs $(docker ps -q --filter "name=gluetun") 2>&1 | grep -iE "port forward|forwarded port"
```

You should see a forwarded port assigned. If you see `API IP address not found`, confirm the running compose hardcodes Docker outbound CIDRs (`10.0.1.0/24,172.16.0.0/12`) and that `LAN_SUBNET` does not include `10.0.0.0/8`. Keep `SERVER_REGIONS=Algeria,India,China` unless you intentionally change exits. Compose already sets `PORT_FORWARD_ONLY=on`. qBittorrent's listen port is synced by `qbittorrent-init/20-sync-forwarded-port.sh`, not by Gluetun `VPN_PORT_FORWARDING_UP_COMMAND`.

---

## Phase 7: Configure applications

Access admin services at `http://<BIND_IP>:<port>` from your private network. Jellyfin is public only at **https://movies.mattapps.org**.

| Service | URL |
|---------|-----|
| Seerr | `http://<BIND_IP>:5055` |
| Sonarr | `http://<BIND_IP>:8989` |
| Radarr | `http://<BIND_IP>:7878` |
| Prowlarr | `http://<BIND_IP>:9696` |
| qBittorrent | `http://<BIND_IP>:8080` |
| Jellyfin | `https://movies.mattapps.org` |

Configure in this order — later steps depend on earlier ones.

### Step 7.1 — qBittorrent

URL: `http://<BIND_IP>:8080`

The compose file mounts `qbittorrent-init/` to `/custom-cont-init.d` (must be **root-owned** on the host). On every start it sets save path `/data/torrents`, incomplete path `/data/torrents/incomplete`, category **`tv`** → `/data/torrents/tv`, category **`movies`** → `/data/torrents/movies`, and enables localhost auth bypass. `20-sync-forwarded-port.sh` is the listen-port source of truth.

1. Get the temporary password from logs:
   ```bash
   docker logs $(docker ps -q --filter "name=qbittorrent")
   ```
2. Log in as `admin` with the temporary password.
3. **Settings → Web UI** → change username and password.
4. **Settings → Downloads** → confirm default save path is `/data/torrents`.
5. **Settings → Connection** → confirm **UPnP** is disabled.
6. Click **Save**.

### Step 7.2 — Prowlarr

URL: `http://<BIND_IP>:9696`

1. **Settings → General** → set **Prowlarr Server URL** to `http://gluetun:9696`.
2. **Settings → General** → set authentication (Forms login recommended).
3. **Settings → Indexers → Indexer Proxies** → add **FlareSolverr**:
   - Host: `http://127.0.0.1:8191`
   - Tag: `flaresolverr`
4. **Indexers** → **Add Indexer** → add your torrent indexers. For Cloudflare-protected sites (e.g. **1337x**), apply the `flaresolverr` tag.
5. **Settings → Apps** → **Add Application**:
   - **Sonarr** — Prowlarr Server: `http://gluetun:9696`, Sonarr Server: `http://sonarr:8989`
   - **Radarr** — Prowlarr Server: `http://gluetun:9696`, Radarr Server: `http://radarr:7878`
6. Test each connection and save.

> FlareSolverr runs through the VPN alongside Prowlarr. Cloudflare-protected indexers like 1337x require the `flaresolverr` tag on the indexer.

### Step 7.3 — Sonarr

URL: `http://<BIND_IP>:8989`

1. **Settings → General** → note the **API Key**; enable authentication.
2. **Settings → Media Management** → enable **Use Hardlinks instead of Copy**.
3. **Settings → Media Management → Root Folders** → add `/data/media/tv`.
4. **Settings → Download Clients** → **Add** → qBittorrent:
   - Host: `gluetun`, Port: `8080`, Category: `tv`
5. Return to Prowlarr and complete Sonarr app sync.

### Step 7.4 — Radarr

URL: `http://<BIND_IP>:7878`

1. **Settings → General** → note the **API Key**; enable authentication.
2. **Settings → Media Management** → enable **Use Hardlinks instead of Copy**.
3. **Settings → Media Management → Root Folders** → add `/data/media/movies`.
4. **Settings → Download Clients** → **Add** → qBittorrent:
   - Host: `gluetun`, Port: `8080`, Category: `movies`
5. Return to Prowlarr and complete Radarr app sync.

### Step 7.5 — Jellyfin

URL: `https://movies.mattapps.org`

1. Complete Jellyfin setup wizard (create local admin account).
2. **Dashboard → Libraries** → add `/data/media/movies` and `/data/media/tv`.
3. **Dashboard → Networking** → confirm **Published Server URL** is `https://movies.mattapps.org`.

### Step 7.6 — Seerr

URL: `http://<BIND_IP>:5055`

1. **Settings → Jellyfin**:
   - Internal URL: `http://jellyfin:8096`
   - External URL: `https://movies.mattapps.org`
   - Jellyfin admin username and password
2. **Settings → Services → Sonarr** — hostname `sonarr`, port `8989`.
3. **Settings → Services → Radarr** — hostname `radarr`, port `7878`.

If Seerr was previously configured for another media server, reset media server settings in the UI or clear `${CONFIG_ROOT}/seerr` and reconfigure:

```bash
docker logs $(docker ps -q --filter "name=seerr") 2>&1 | tail -50
```

---

## End-to-end test

1. [ ] Open Seerr on Tailscale → request a movie.
2. [ ] Radarr shows the movie as wanted / starts searching.
3. [ ] qBittorrent receives a torrent and downloads over VPN.
4. [ ] Radarr imports to `/data/media/movies`.
5. [ ] Jellyfin shows the new movie at `https://movies.mattapps.org`.
6. [ ] Repeat with a TV show via Sonarr.

---

## Post-implementation checklist

| Item | Done |
|------|------|
| Admin UIs reachable on Tailscale (`BIND_IP:port`) | ☐ |
| Jellyfin reachable at `https://movies.mattapps.org` | ☐ |
| No Dokploy Traefik domains assigned | ☐ |
| Gluetun container healthy | ☐ |
| VPN IP differs from server IP | ☐ |
| qBittorrent password changed | ☐ |
| Sonarr/Radarr/Prowlarr authentication enabled | ☐ |
| Jellyfin Published Server URL set to `https://movies.mattapps.org` | ☐ |
| Seerr connected to Jellyfin, Sonarr, Radarr | ☐ |
| `${CONFIG_ROOT}` backup scheduled | ☐ |
| Sidecar watchdog timer enabled | ☐ |
| Docker packages `apt-mark hold` on home-svr | ☐ |
| GitHub App **Dokploy-Home-svr** → `rdeveloper1925/jellyfin_stack` | ☐ |

---

## Quick reference

### Internal Docker hostnames (container-to-container)

| From | To | Address |
|------|-----|---------|
| Sonarr / Radarr | qBittorrent | `gluetun:8080` |
| Sonarr / Radarr | Prowlarr | `gluetun:9696` |
| Prowlarr | Sonarr | `sonarr:8989` |
| Prowlarr | Radarr | `radarr:7878` |
| Seerr | Jellyfin | `jellyfin:8096` |
| Seerr | Sonarr | `sonarr:8989` |
| Seerr | Radarr | `radarr:7878` |

### Tailscale access URLs

Admin UIs bind to `${BIND_IP}`. Jellyfin is excluded — use `https://movies.mattapps.org`.

| Service | Port |
|---------|------|
| Seerr | 5055 |
| Sonarr | 8989 |
| Radarr | 7878 |
| Prowlarr | 9696 |
| qBittorrent (via gluetun) | 8080 |
| Prowlarr (via gluetun) | 9696 |

### Redeploy after changes

When you update `docker-compose.yml` or environment variables in home-svr Dokploy:

1. Save changes (GitHub provider + Environment). Prefer a careful `docker compose up -d` on the host so only changed services recreate — Jellyfin/Plex should stay up; VPN sidecars may bounce.
2. Click **Deploy** only when you need Dokploy to re-clone. Leave Auto Deploy off.
3. Verify affected containers restarted cleanly. Confirm the sidecar watchdog timer is enabled (`systemctl list-timers jellyfin-stack-sidecar-watchdog.timer`).

---

## Related docs

- [README.md](README.md) — architecture, security, maintenance, troubleshooting
- [.env.example](.env.example) — environment variable template
- [Dokploy Docker Compose docs](https://docs.dokploy.com/docs/core/docker-compose/example)
- [Cloudflare Tunnel docs](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
- [TRaSH Guides](https://trash-guides.info/) — quality profiles and folder naming
