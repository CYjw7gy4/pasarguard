#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# railway-bootstrap.sh
#
# Entrypoint for running this panel on Railway (or any PaaS that gives you a
# single HTTP port). It performs the one-time setup that the Dockerfile does at
# build time when you deploy the image yourself — verifying the Node runtime,
# creating the Python venv, installing the pinned wheels and downloading the
# vpn-ui binary — and then execs the normal panel gateway.
#
# Markers live in $RAILWAY_VOLUME_MOUNT_PATH (default /persistent) so the heavy
# work happens once per volume, not on every restart.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"
cd "$ROOT"

DATA_DIR="${RAILWAY_VOLUME_MOUNT_PATH:-/persistent}"
PORT="${PORT:-8080}"
PUBLIC_HOST="${RAILWAY_PUBLIC_DOMAIN:-${PASARGUARD_PUBLIC_HOST:-}}"

VPN_UI_VERSION="${VPN_UI_VERSION:-v1.9.4}"
VPN_UI_SHA256="${VPN_UI_SHA256:-18ec321d9074b319bd5756508bbc523ab5d95450b832c406acdd72e987a2da8f}"
PY_TARBALL="https://github.com/astral-sh/python-build-standalone/releases/download/20261026/cpython-3.14.10%2B20261026-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz"
PY_SHA256="4d3c16c59ed0802a3d1d34d8bce504b15ceeaff39d62dadecc6a9fa803412aed"

log()  { printf '\033[36m[bootstrap] %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m[bootstrap] ✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m[bootstrap] ! %s\033[0m\n' "$*"; }
die()  { printf '\033[31m[bootstrap] ✖ %s\033[0m\n' "$*" >&2; exit 1; }

[[ -n $PUBLIC_HOST ]] || die "RAILWAY_PUBLIC_DOMAIN is empty. Generate a public domain for the service first."
[[ -d $DATA_DIR ]] || die "Volume not mounted at $DATA_DIR — add a Railway volume mounted at $DATA_DIR."

# ---------------------------------------------------------------- base facts
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ARCH=x86_64 ;;
  *) die "This image ships an x86_64 vpn-ui binary; '$ARCH' is not supported. Use an amd64 instance." ;;
esac

if [[ -z ${ADMIN_PASSWORD:-} ]]; then
  ADMIN_PASSWORD="$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z2-9' | head -c 20 || true)"
  export ADMIN_PASSWORD
  printf '%s\n' "$ADMIN_PASSWORD" > "$DATA_DIR/admin-password.txt"
  chmod 600 "$DATA_DIR/admin-password.txt"
  warn "No ADMIN_PASSWORD variable was set — generated one (stored in $DATA_DIR/admin-password.txt)."
fi
export ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"

# ---------------------------------------------------------------- env the panel needs
# Railway terminates TLS at its edge and forwards plain HTTP to $PORT, so the
# panel must not try to serve TLS itself (PUBLIC_TLS=0) while the subscription
# links still advertise https.
export RAILWAY_VOLUME_MOUNT_PATH="$DATA_DIR"
export RAILWAY_STATE_FILE="${RAILWAY_STATE_FILE:-$DATA_DIR/state.json}"
export SERVER_IP="$PUBLIC_HOST"
export PANEL_HOST="$PUBLIC_HOST"
export SERVER_PORT="$PORT"
export RAILWAY_ADVERTISED_PORT="$PORT"
export PUBLIC_TLS="${PUBLIC_TLS:-0}"
export SUB_SCHEME="${SUB_SCHEME:-https}"
export PG_MANAGED_SUB_ORIGIN="${PG_MANAGED_SUB_ORIGIN:-https://$PUBLIC_HOST}"
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1
export UV_THREADPOOL_SIZE="${UV_THREADPOOL_SIZE:-4}"
export MALLOC_ARENA_MAX=1

# Single-port hosting: Railway publishes one TCP port only (no UDP), so every
# generated inbound must fall back to TCP. Existing data is never migrated.
export TCP_ONLY="${TCP_ONLY:-true}"
export DISABLE_UDP="${DISABLE_UDP:-1}"

# The launcher reads this file to learn its public address.
printf '{"public_host":"%s","public_port":%s}\n' "$PUBLIC_HOST" "$PORT" > "$ROOT/server-config.json"

# ---------------------------------------------------------------- node
node --version >/dev/null 2>&1 || die "Node.js is not on PATH. Set the runtime to Node 22 (see nixpacks.toml) or use the Dockerfile."
ok "node $(node --version)"

# ---------------------------------------------------------------- python + wheels
if [[ ! -x "$ROOT/.venv/bin/python" || ! -f "$DATA_DIR/.deps-ready" ]]; then
  log "Preparing Python 3.14 runtime (one-time, a few minutes)…"
  rm -rf "$ROOT/py314" "$ROOT/python" "$ROOT/.venv"
  curl -fLsS --retry 3 --connect-timeout 30 --max-time 900 "$PY_TARBALL" -o "$ROOT/.python314.tar.gz"
  echo "$PY_SHA256  $ROOT/.python314.tar.gz" | sha256sum -c - >/dev/null
  tar -xzf "$ROOT/.python314.tar.gz" -C "$ROOT"
  mv "$ROOT/python" "$ROOT/py314"
  rm -f "$ROOT/.python314.tar.gz"
  "$ROOT/py314/bin/python3" -m venv "$ROOT/.venv"
  ok "python $("$ROOT/.venv/bin/python" --version 2>&1 | awk '{print $2}')"
fi

if [[ ! -f "$DATA_DIR/.deps-ready" ]]; then
  log "Installing pinned Python dependencies…"
  mkdir -p "$ROOT/pasarguard-native/pylibs"
  "$ROOT/.venv/bin/pip" install --no-cache-dir --disable-pip-version-check --no-compile \
      --retries 5 --timeout 60 \
      --target "$ROOT/pasarguard-native/pylibs" -r requirements-freeze.txt webauthn >"$DATA_DIR/pip.log" 2>&1 \
    || { tail -30 "$DATA_DIR/pip.log"; die "pip install failed (see $DATA_DIR/pip.log)"; }
  "$ROOT/.venv/bin/pip" install --no-cache-dir --disable-pip-version-check --no-compile --no-deps \
      --retries 5 --timeout 60 --upgrade \
      --target "$ROOT/pasarguard-native/pylibs" pasarguard-node-bridge==0.9.4 >>"$DATA_DIR/pip.log" 2>&1 \
    || { tail -30 "$DATA_DIR/pip.log"; die "pip install (node-bridge) failed"; }
  find "$ROOT/pasarguard-native/pylibs" -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
  touch "$DATA_DIR/.deps-ready"
  ok "Python dependencies installed"
fi

# ---------------------------------------------------------------- vpn-ui binary
if [[ ! -x "$ROOT/vpn/vpn-ui-amd64" ]]; then
  log "Downloading vpn-ui ${VPN_UI_VERSION} (~350 MB, one-time)…"
  mkdir -p "$ROOT/vpn"
  curl -fL --retry 3 --retry-delay 3 --retry-all-errors --connect-timeout 30 --max-time 1800 \
      "https://github.com/Sir-MmD/vpn-ui/releases/download/${VPN_UI_VERSION}/vpn-ui-amd64" \
      -o "$ROOT/vpn/vpn-ui-amd64.part"
  echo "${VPN_UI_SHA256}  $ROOT/vpn/vpn-ui-amd64.part" | sha256sum -c - >/dev/null
  mv "$ROOT/vpn/vpn-ui-amd64.part" "$ROOT/vpn/vpn-ui-amd64"
  chmod 755 "$ROOT/vpn/vpn-ui-amd64"
  ok "vpn-ui ready"
fi

chmod +x "$ROOT"/*.sh 2>/dev/null || true

log "Starting the panel on 0.0.0.0:${PORT} for https://${PUBLIC_HOST}"
exec node "$ROOT/index.js"
