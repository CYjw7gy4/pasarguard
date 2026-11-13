#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# deploy.sh — one-command install / update for a forked copy of this repo.
#
#   sudo ./deploy.sh                 # https (self-signed) on port from .env
#   sudo ./deploy.sh --http          # plain http
#   sudo ./deploy.sh --port 8443     # change the public port
#   sudo ./deploy.sh --update        # rebuild + restart, keeping all data
#   sudo ./deploy.sh --logs          # follow container logs
#
# The first run creates .env (if missing), builds the image and waits for the
# panel. Every later run is safe: data lives in the docker volume
# "pasarguard-data" and is never deleted by this script.
# ---------------------------------------------------------------------------
set -Eeuo pipefail
SELF="$(cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")"
cd -- "$(dirname -- "$SELF")"

MODE=""
PORT_OVERRIDE=""
ACTION="up"

usage() {
  awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$SELF"
  exit "${1:-0}"
}

while (($#)); do
  case "$1" in
    --http)    MODE=http ;;
    --https)   MODE=https ;;
    --port)    PORT_OVERRIDE="${2:?--port needs a number}"; shift ;;
    --update)  ACTION=update ;;
    --logs)    ACTION=logs ;;
    --down)    ACTION=down ;;
    --restart) ACTION=restart ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
  shift
done

die() { printf '\n\033[31m✖ %s\033[0m\n' "$*" >&2; exit 1; }
ok()  { printf '\033[32m✔ %s\033[0m\n' "$*"; }
info(){ printf '\033[36m• %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- preconditions
[[ $(uname -s) == Linux ]] || die "This stack targets Linux (amd64/arm64). On macOS/Windows use WSL2 or a VPS."
command -v docker >/dev/null || die "Docker is not installed. Install it:  curl -fsSL https://get.docker.com | sh"
docker compose version >/dev/null 2>&1 || die "The Docker Compose v2 plugin is required (docker compose), not docker-compose."
docker info >/dev/null 2>&1 || die "Cannot talk to the Docker daemon. Are you root, or in the docker group?"
command -v curl >/dev/null || die "curl is required."

# ---------------------------------------------------------------- .env handling
random_password() {
  # 20 chars, alphanumeric only, no ambiguous characters.
  # Read a fixed chunk first so no pipe gets SIGPIPE under `set -o pipefail`.
  local chunk
  chunk=$(head -c 8192 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z2-9' || true)
  printf '%s' "${chunk:0:20}"
}

detect_host() {
  curl -4fsS --connect-timeout 4 --max-time 8 https://api.ipify.org 2>/dev/null ||
  curl -4fsS --connect-timeout 4 --max-time 8 https://icanhazip.com 2>/dev/null || true
}

# set_env KEY VALUE — portable in-place edit of one key in .env
set_env() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  if grep -q "^${key}=" .env; then
    sed -e "s|^${key}=.*|${key}=${value}|" .env >"$tmp"
  else
    { cat .env; printf '%s=%s\n' "$key" "$value"; } >"$tmp"
  fi
  mv -f "$tmp" .env
  chmod 600 .env
}

if [[ ! -f .env ]]; then
  info "No .env found — creating one."
  cp .env.example .env
  host="${PASARGUARD_HOST:-$(detect_host)}"
  [[ -n $host ]] || die "Could not auto-detect the public IP. Re-run as:  PASARGUARD_HOST=1.2.3.4 ./deploy.sh"
  [[ $host =~ ^[A-Za-z0-9.-]+$ ]] || die "Detected host '$host' looks invalid. Set PASARGUARD_HOST manually."

  port="${PASARGUARD_PORT:-20004}"
  [[ ${PORT_OVERRIDE:-} ]] && port="$PORT_OVERRIDE"
  [[ $port =~ ^[0-9]{1,5}$ ]] || die "Port must be numeric."

  scheme="${MODE:-${PASARGUARD_SCHEME:-https}}"
  tls=1; [[ $scheme == http ]] && tls=0
  password="${PASARGUARD_PASSWORD:-$(random_password)}"

  # Portable in-place edit (no GNU-only sed -i).
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  sed -e "s|^SERVER_IP=.*|SERVER_IP=${host}|" \
      -e "s|^VPN_PORT=.*|VPN_PORT=${port}|" \
      -e "s|^PANEL_HOST=.*|PANEL_HOST=${host}|" \
      -e "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=${password}|" \
      -e "s|^SUB_SCHEME=.*|SUB_SCHEME=${scheme}|" \
      -e "s|^PUBLIC_TLS=.*|PUBLIC_TLS=${tls}|" .env >"$tmp"
  mv -f "$tmp" .env; trap - EXIT
  chmod 600 .env
  ok "Created .env for ${host}:${port} (${scheme})."
  printf '\n  Admin username : admin\n  Admin password : %s\n' "$password"
  printf '  (also stored in .env — change it inside the panel after first login)\n\n'
  sleep 1
else
  chmod 600 .env
  ok "Existing .env kept (data and password are preserved)."

  # --port / --http on an existing install edits .env only; data is untouched.
  if [[ -n $PORT_OVERRIDE ]]; then
    [[ $PORT_OVERRIDE =~ ^[0-9]{1,5}$ ]] || die "--port must be numeric."
    set_env VPN_PORT "$PORT_OVERRIDE"
    ok "Port set to ${PORT_OVERRIDE}."
  fi
  if [[ -n $MODE ]]; then
    tls=1; [[ $MODE == http ]] && tls=0
    set_env SUB_SCHEME "$MODE"
    set_env PUBLIC_TLS "$tls"
    ok "Access mode set to ${MODE}."
  fi
fi

# shellcheck disable=SC1091
set -a; . ./.env; set +a
PORT="${VPN_PORT:-20004}"
HOST="${PANEL_HOST:-${SERVER_IP:-localhost}}"
SCHEME="${SUB_SCHEME:-https}"

# ---------------------------------------------------------------- actions
case "$ACTION" in
  down)
    docker compose down
    ok "Stopped. Data volume 'pasarguard-data' is untouched."
    exit 0 ;;
  logs)
    exec docker compose logs -f --tail=200 ;;
esac

docker compose config --quiet || die "compose.yaml / .env combination is invalid."

if [[ $ACTION == update || $ACTION == restart ]]; then
  info "Rebuilding image and recreating the container (data is preserved)…"
  docker compose up -d --build --remove-orphans
else
  info "Building the image — the first build downloads ~350 MB and can take 5-15 min…"
  docker compose up -d --build
fi

# ---------------------------------------------------------------- wait for it
info "Waiting for the panel API to answer (up to 5 min)…"
ready=0
for ((i = 0; i < 150; i++)); do
  code=$(curl --noproxy '*' -k -s -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 3 \
        "${SCHEME}://127.0.0.1:${PORT}/" || true)
  # Any HTTP answer (200/301/401/403…) means the process is serving.
  if [[ $code =~ ^(200|301|302|401|403|404)$ ]]; then ready=1; break; fi
  sleep 2
done

if ((ready == 0)); then
  printf '\n\033[31m✖ The panel did not answer in time.\033[0m\n' >&2
  printf '  Inspect the logs:  sudo ./deploy.sh --logs\n' >&2
  exit 1
fi

# ---------------------------------------------------------------- summary
ADMIN_USER=$(sed -n 's/^ADMIN_USERNAME=//p' .env | tail -1); ADMIN_USER=${ADMIN_USER:-admin}
ADMIN_PASS=$(sed -n 's/^ADMIN_PASSWORD=//p' .env | tail -1)
line="════════════════════════════════════════════════════════════"
printf '\n\033[32m%s\033[0m\n' "$line"
cat <<EOF
  PasarGuard is up.

  Panel      : ${SCHEME}://${HOST}:${PORT}/
  Dashboard  : ${SCHEME}://${HOST}:${PORT}/TeamGuccI/pasarguard/
  Username   : ${ADMIN_USER}
  Password   : ${ADMIN_PASS}

  Open TCP ${PORT} and UDP ${PORT} in your firewall / security group.
EOF
if [[ $SCHEME == https ]]; then
  echo "  The certificate is self-signed — the browser will warn once."
else
  echo "  WARNING: HTTP is unencrypted. Put it behind a TLS reverse proxy for real use."
fi
cat <<EOF

  Logs    : sudo ./deploy.sh --logs
  Update  : git pull && sudo ./deploy.sh --update
  Stop    : sudo ./deploy.sh --down
EOF
printf '\033[32m%s\033[0m\n\n' "$line"
