# ---------------------------------------------------------------------------
# PasarGuard / vpn-ui panel image
#
# Stage 1 only borrows the Node runtime; everything else is Python 3.14.
# The heavy vpn-ui binary (~350 MB) is downloaded at build time instead of
# living in the repo, so the git repository stays small and forking is fast.
# ---------------------------------------------------------------------------
FROM node:22-bookworm-slim AS node

FROM python:3.14-slim-bookworm

# Pinned upstream release of the vpn-ui binary.
ARG VPN_UI_VERSION=v1.9.4
ARG VPN_UI_SHA256=18ec321d9074b319bd5756508bbc523ab5d95450b832c406acdd72e987a2da8f

COPY --from=node /usr/local/bin/node /usr/local/bin/node
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash curl ca-certificates unzip procps iproute2 tzdata \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /home/container

# ---- Python dependencies (cached layer: only rebuilds if the freeze changes)
COPY requirements-freeze.txt ./
RUN python -m venv /home/container/.venv \
 && .venv/bin/pip install --no-cache-dir --disable-pip-version-check \
      --retries 5 --timeout 60 \
      --target /home/container/pasarguard-native/pylibs \
      -r requirements-freeze.txt webauthn \
 && .venv/bin/pip install --no-cache-dir --disable-pip-version-check \
      --retries 5 --timeout 60 --no-deps --upgrade \
      --target /home/container/pasarguard-native/pylibs \
      pasarguard-node-bridge==0.9.4

# ---- Application source
COPY . /home/container/

# Restore the dashboard SPA from the packaged build asset.
RUN tar -xzf /home/container/runtime-assets/dashboard-build.tar.gz -C /home/container

# ---- vpn-ui binary (downloaded, never committed to git)
RUN set -eu; \
    mkdir -p /home/container/vpn/bin /home/container/pasarguard-native/data /home/container/vpn/data; \
    curl -fL --retry 5 --retry-delay 2 --retry-all-errors \
         --connect-timeout 30 --max-time 1200 \
         "https://github.com/Sir-MmD/vpn-ui/releases/download/${VPN_UI_VERSION}/vpn-ui-amd64" \
         -o /home/container/vpn/vpn-ui-amd64; \
    echo "${VPN_UI_SHA256}  /home/container/vpn/vpn-ui-amd64" | sha256sum -c -; \
    chmod +x /home/container/vpn/vpn-ui-amd64; \
    chmod +x /home/container/entrypoint.sh /home/container/start.sh /home/container/install.sh /home/container/deploy.sh /home/container/seed-native.sh

ENV RAILWAY_STATE_FILE=/persistent/state.json \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

EXPOSE 20004/tcp 20004/udp

# start.sh clears any stale runtime patch, then hands over to entrypoint.sh.
CMD ["sh", "/home/container/start.sh"]
