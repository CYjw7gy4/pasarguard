#!/bin/sh
set -eu
ulimit -c 0 2>/dev/null || true
cd /home/container
: "${ADMIN_PASSWORD:?missing admin password}"
# The data volume must be mounted, otherwise every restart would silently wipe
# the panel database. Accept either the standard mount point or PG_DATA_DIR.
DATA_DIR="${RAILWAY_VOLUME_MOUNT_PATH:-${PG_DATA_DIR:-/persistent}}"
[ -d "$DATA_DIR" ] || { echo "Data volume '$DATA_DIR' is not mounted; refusing to start."; exit 1; }
if ! touch "$DATA_DIR/.write-test" 2>/dev/null; then
  echo "Data volume '$DATA_DIR' is not writable; check permissions (chown 0:0 or docker volume)."; exit 1
fi
rm -f "$DATA_DIR/.write-test"
if [ "$DATA_DIR" != "/persistent" ]; then ln -sfn "$DATA_DIR" /persistent; fi
mkdir -p /persistent/vpn-data /persistent/openvpn /persistent/native-data /home/container/vpn /home/container/pasarguard-native
# Clean removed/disabled legacy portal & chart state from persistent storage
rm -rf /persistent/native-data/admin_panels.json \
       /persistent/native-data/edge_secret.txt \
       /persistent/native-data/admin-chart \
       /persistent/vpn-data/ssh_host_ed25519_key.json \
       /persistent/openvpn/ssh_host_ed25519_key.json
# VPN-UI initializes a new empty database on first start.
if [ ! -f /persistent/native-data/pasarguard.db ]; then cp /home/container/native-fresh.db /persistent/native-data/pasarguard.db; fi
rm -rf /home/container/vpn/data /home/container/vpn/openvpn /home/container/pasarguard-native/data
ln -s /persistent/vpn-data /home/container/vpn/data
ln -s /persistent/openvpn /home/container/vpn/openvpn
ln -s /persistent/native-data /home/container/pasarguard-native/data
# Keep OpenVPN traffic on the Amsterdam service's direct egress.
if [ ! -e /persistent/vpn-data/warp-route.json ]; then echo '{"openvpn":false}' > /persistent/vpn-data/warp-route.json; fi
if [ ! -f /persistent/native-seeded ]; then
  echo 'Initializing fresh PasarGuard data'
  if [ -f /persistent/native-data/pasarguard-empty-backup.db ]; then
    /home/container/.venv/bin/python -c "import sqlite3; c=sqlite3.connect('/persistent/native-data/pasarguard.db'); assert c.execute('select count(*) from users').fetchone()[0] == 0; assert c.execute('select count(*) from admins').fetchone()[0] == 1"
    cp /home/container/native-fresh.db /persistent/native-data/pasarguard-empty-backup.db
  else
    bash /home/container/seed-native.sh
  fi
  /home/container/.venv/bin/python /home/container/repair-native-schema.py
  touch /persistent/native-seeded
fi
touch /home/container/pasarguard-native/data/runtime-writes.enabled
/home/container/.venv/bin/python /home/container/wait-seed-services.py &
exec node /home/container/index.js
