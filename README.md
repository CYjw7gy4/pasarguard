# PasarGuard / vpn-ui — self-hosted panel

Deployable copy of the PasarGuard (vpn-ui) panel stack: one container, one port,
one `docker compose up`. Built for the "fork it on GitHub and run it anywhere"
workflow — nothing is fetched from Google Drive, Dropbox or any private link.

```
git clone https://github.com/<you>/<this-repo>.git
cd <this-repo>
sudo ./deploy.sh
```

That's it. The script detects the public IP, generates a random admin password,
writes `.env`, builds the image and waits until the panel answers.

---

## 1. Requirements

| | Minimum | Recommended |
|---|---|---|
| OS | Linux x86_64 (or arm64 via emulation) | Ubuntu 22.04 / 24.04, Debian 12 |
| CPU | 1 vCPU | 2 vCPU |
| RAM | 1 GB (build needs ~1.5 GB) | 2 GB |
| Disk | 5 GB free | 10 GB |
| Software | Docker Engine + Compose v2 plugin | same |

Install Docker on a fresh VPS:

```bash
curl -fsSL https://get.docker.com | sh
```

Firewall: open **TCP** and **UDP** on the panel port (default `20004`).

```bash
sudo ufw allow 20004/tcp && sudo ufw allow 20004/udp
# or with iptables/nftables, and in your provider's security group
```

---

## 2. Deploy

```bash
sudo ./deploy.sh                 # HTTPS with a self-signed certificate
sudo ./deploy.sh --http          # plain HTTP (put it behind a TLS proxy)
sudo ./deploy.sh --port 8443     # use a different public port
```

At the end the script prints the panel URL, the dashboard URL and the admin
password. Everything is also stored in `.env`:

```
PANEL      https://<your-ip>:20004/
DASHBOARD  https://<your-ip>:20004/TeamGuccI/pasarguard/
USERNAME   admin
PASSWORD   (random, generated on first run — see .env)
```

The first build downloads the ~350 MB `vpn-ui` binary and the Python
dependencies, so it takes 5–15 minutes on a small VPS. Later builds are cached.

### Non-interactive / scripted install

```bash
PASARGUARD_HOST=panel.example.com \
PASARGUARD_PORT=443 \
PASARGUARD_PASSWORD='a-strong-password' \
PASARGUARD_SCHEME=https \
sudo -E ./deploy.sh
```

---

## 3. Day-2 operations

```bash
sudo ./deploy.sh --logs       # follow logs
sudo ./deploy.sh --update     # git pull, then rebuild + restart (data kept)
sudo ./deploy.sh --restart     # restart without rebuilding
sudo ./deploy.sh --down       # stop (data volume kept)
```

Data lives in the Docker volume **`pasarguard-data`** and survives
`--down`, `--update` and image rebuilds. It is only destroyed by:

```bash
docker compose down -v        # ⚠ deletes users, configs, certificates
```

### Backup

```bash
docker run --rm -v pasarguard-data:/data -v "$PWD":/backup alpine \
  tar czf /backup/pasarguard-$(date +%F).tar.gz -C /data .
```

Restore = stop the stack, put the archive back into the same volume, start.

### Put it on a domain with a real certificate

Terminate TLS in front of the container (nginx, Caddy) and proxy to
`http://127.0.0.1:20004`:

```caddy
panel.example.com {
    reverse_proxy 127.0.0.1:20004
}
```

Then set `SERVER_IP`/`PANEL_HOST` to the domain in `.env` and
`SUB_SCHEME=https`, `PUBLIC_TLS=0` (the proxy already does TLS), and run
`sudo ./deploy.sh --update`.

---

## 4. Deploying to a PaaS

The same image runs on any Docker host.

* **Railway** — `railway.json` is included. Add a volume mounted at
  `/persistent`, set `ADMIN_PASSWORD`, `SERVER_IP`, `PANEL_HOST`, `VPN_PORT`.
* **Fly.io / Render / Koyeb** — build from this Dockerfile, mount a persistent
  volume at `/persistent`, expose the port as TCP **and** UDP.
* **Kubernetes** — the container is stateless apart from `/persistent`; a
  `StatefulSet` with a PVC and a `LoadBalancer` service (TCP+UDP) is enough.

Any platform that only gives you an HTTP port (shared PaaS, serverless) will
**not** work for the VPN inbounds themselves — TCP/UDP egress is required.

---

## 5. Configuration reference

All settings live in `.env` (see `.env.example`):

| Key | Default | Meaning |
|---|---|---|
| `SERVER_IP` | auto-detected | Public IP or domain, no scheme |
| `VPN_PORT` | `20004` | Single TCP+UDP port for panel + inbounds |
| `PANEL_HOST` | = `SERVER_IP` | Host used in links/cookies |
| `ADMIN_USERNAME` | `admin` | First admin (fresh volume only) |
| `ADMIN_PASSWORD` | random | First admin password (fresh volume only) |
| `SUB_SCHEME` | `https` | Scheme used in subscription links |
| `PUBLIC_TLS` | `1` | `1` = serve TLS itself, `0` = behind a TLS proxy |

Changing `ADMIN_PASSWORD` later does **not** change the panel password — use the
panel UI for that (Settings → Admins).

---

## 6. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `deploy.sh` says *Cannot talk to the Docker daemon* | Run with `sudo`, or `sudo usermod -aG docker $USER` and re-login |
| Build fails at the `curl` step | No outbound access to `github.com`; set a mirror and change `VPN_UI_VERSION` in the Dockerfile |
| Container restarts: *Data volume is not mounted* | The volume is missing/permission-denied; check `docker volume ls` and `docker compose logs` |
| Panel opens but no VPN connects | Port not open for **UDP** as well, or a cloud firewall blocks it |
| Browser warns about the certificate | Expected with the self-signed default; put it behind a TLS proxy for production |
| Forgot the admin password | Inside the panel you cannot reset it blind — restore a backup, or start a fresh volume (`docker compose down -v`) and set a new one in `.env` |

Logs always:

```bash
sudo ./deploy.sh --logs
```

---

## 7. Repository layout

```
Dockerfile              multi-stage build, vpn-ui binary fetched at build time
compose.yaml            single service + named data volume + healthcheck
deploy.sh               the one command you need (install / update / logs)
install.sh              thin wrapper kept for compatibility -> deploy.sh
.env.example            every supported setting, documented
entrypoint.sh           volume checks, data seeding, exec index.js
index.js                Node gateway: dashboard, API proxy, node launcher
bootstrap.js            in-container first-run seeding
seed-native.sh          creates the initial owner/admin row
pasarguard-native/      Python backend (FastAPI) + dashboard SPA
runtime-assets/         dashboard build, OpenVPN / glibc runtime blobs
vendor/ws               vendored websocket library (no npm install needed)
```

Upstream projects: `PasarGuard/PasarGuard` (panel logic) and
`Sir-MmD/MmD-Panel` / `vpn-ui` (binary). This repository only packages them for
repeatable self-hosting; review the upstream licences before redistributing.

---

## 8. Security notes

* `.env` is git-ignored and `chmod 600` — never commit real credentials.
* The default certificate is self-signed: fine for testing, not for real users.
* Everything the panel serves is unauthenticated only at the login page; keep
  the host patched (`git pull && ./deploy.sh --update`).
* Rotate the admin password after the first login.
