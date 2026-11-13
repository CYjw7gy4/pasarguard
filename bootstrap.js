'use strict';
process.env.UV_THREADPOOL_SIZE = '1';
const fs = require('fs');
const cp = require('child_process');
const root = '/home/container';
process.chdir(root);
const configFile = root + '/server-config.json';
let config;
try { config = JSON.parse(fs.readFileSync(configFile, 'utf8')); }
catch (e) { console.error('Set public_host in server-config.json before starting.'); process.exit(1); }
const publicHost = String(process.env.PASARGUARD_PUBLIC_HOST || config.public_host || '').trim();
if (!publicHost || publicHost === 'YOUR_PUBLIC_IP_OR_DOMAIN' || publicHost.length > 253 || !/^[A-Za-z0-9.-]+$/.test(publicHost) || publicHost.startsWith('.') || publicHost.endsWith('.') || publicHost.includes('..')) {
  console.error('Set public_host to your allocated public IP or domain in server-config.json (no http:// and no port).'); process.exit(1);
}
const publicPort = String(process.env.SERVER_PORT || config.public_port || '').trim();
if (!/^\d{1,5}$/.test(publicPort) || Number(publicPort) < 1 || Number(publicPort) > 65535) {
  console.error('Allocated port is missing. Set public_port in server-config.json.'); process.exit(1);
}
process.umask(0o077);
function run(name, cmd) {
  console.log('[install] ' + name);
  const result = cp.spawnSync('/bin/bash', ['-c', 'set -euo pipefail\nulimit -c 0 2>/dev/null || true\n' + cmd], { cwd: root, stdio: 'inherit', env: process.env });
  if (result.error || result.status !== 0) {
    console.error('[install] FAILED ' + name + ' status=' + (result.status === null ? 'signal' : result.status));
    process.exit(1);
  }
}
const pwPath = root + '/.katapanel-secret';
if (!fs.existsSync(pwPath)) fs.writeFileSync(pwPath, (process.env.ADMIN_PASSWORD || 'GUCCi') + '\n', { mode: 0o600, flag: 'wx' });
const pass = (process.env.ADMIN_PASSWORD || fs.readFileSync(pwPath, 'utf8')).trim();
Object.assign(process.env, {
  ADMIN_PASSWORD: pass, SERVER_IP: publicHost, PANEL_HOST: publicHost,
  SERVER_PORT: publicPort, PORT: publicPort, RAILWAY_ADVERTISED_PORT: publicPort,
  RAILWAY_VOLUME_MOUNT_PATH: root + '/persistent', RAILWAY_STATE_FILE: root + '/persistent/state.json',
  PG_MANAGED_SUB_ORIGIN: 'http://' + publicHost + ':' + publicPort,
  PUBLIC_TLS: '0', PYTHONDONTWRITEBYTECODE: '1', PYTHONUNBUFFERED: '1',
  MALLOC_ARENA_MAX: '1', UV_THREADPOOL_SIZE: '1',
  GOMAXPROCS: '1', GOGC: '50',
  TOKIO_WORKER_THREADS: '1', RAYON_NUM_THREADS: '1',
  OPENBLAS_NUM_THREADS: '1', OMP_NUM_THREADS: '1',
  NODE_OPTIONS: '--v8-pool-size=1'
});
try { fs.rmSync(root + '/vpn/core', { force: true }); } catch (_) {}
try {
  if (fs.existsSync(root + '/vpn/bin')) {
    for (const fn of fs.readdirSync(root + '/vpn/bin')) {
      if (fn.startsWith('core_crash_') || fn === 'core') {
        try { fs.rmSync(root + '/vpn/bin/' + fn, { force: true }); } catch (_) {}
      }
    }
  }
} catch (_) {}
if (!fs.existsSync(root + '/.katapanel-source-ready')) {
  console.log('[install] preparing standalone hosting paths');
  const files = ['start.sh', 'entrypoint.sh', 'wait-seed-services.py', 'upgrade-native.py', 'pasarguard-native/run-native.sh.real'];
  for (const f of files) {
    const p = root + '/' + f;
    let code = fs.readFileSync(p, 'utf8');
    code = code.replace(/(?<!\/home\/container)\/persistent/g, '/home/container/persistent');
    fs.writeFileSync(p, code);
  }
  fs.closeSync(fs.openSync(root + '/.enable-pasarguard-native', 'a'));
  fs.closeSync(fs.openSync(root + '/.katapanel-source-ready', 'a'));
}
if (!fs.existsSync(root + '/.katapanel-python314-ready')) run('install verified Python 3.14 runtime', `rm -rf /home/container/py314 /home/container/python /home/container/.venv
  curl -fLsS --retry 2 --connect-timeout 30 --max-time 600 'https://github.com/astral-sh/python-build-standalone/releases/download/20261026/cpython-3.14.10%2B20261026-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz' -o /home/container/.python314.tar.gz
  echo '4d3c16c59ed0802a3d1d34d8bce504b15ceeaff39d62dadecc6a9fa803412aed  /home/container/.python314.tar.gz' | sha256sum -c -
  tar -xzf /home/container/.python314.tar.gz -C /home/container
  mv /home/container/python /home/container/py314
  rm -f /home/container/.python314.tar.gz
  /home/container/py314/bin/python3 -m venv /home/container/.venv
  touch /home/container/.katapanel-python314-ready`);
if (!fs.existsSync(root + '/.katapanel-python-ready')) {
  run('install Python requirements', `mkdir -p /home/container/pasarguard-native/pylibs
  /home/container/.venv/bin/pip install --no-cache-dir --disable-pip-version-check --no-compile --target /home/container/pasarguard-native/pylibs -r requirements-freeze.txt webauthn > /home/container/.kata-pip.log 2>&1 || { tail -20 /home/container/.kata-pip.log; exit 1; }
  /home/container/.venv/bin/pip install --no-cache-dir --disable-pip-version-check --no-compile --no-deps --upgrade --target /home/container/pasarguard-native/pylibs pasarguard-node-bridge==0.9.4 >> /home/container/.kata-pip.log 2>&1 || { tail -20 /home/container/.kata-pip.log; exit 1; }
  find /home/container/pasarguard-native/pylibs -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
  rm -f /home/container/.kata-pip.log
  touch /home/container/.katapanel-python-ready`);
}
if (!fs.existsSync(root + '/vpn/vpn-ui-amd64')) {
  run('download and verify VPN-UI runtime', `mkdir -p /home/container/vpn
  curl -fLsS --retry 2 --connect-timeout 30 --max-time 900 https://github.com/Sir-MmD/vpn-ui/releases/download/v1.9.4/vpn-ui-amd64 -o /home/container/vpn/vpn-ui-amd64.part
  echo '18ec321d9074b319bd5756508bbc523ab5d95450b832c406acdd72e987a2da8f  /home/container/vpn/vpn-ui-amd64.part' | sha256sum -c -
  mv /home/container/vpn/vpn-ui-amd64.part /home/container/vpn/vpn-ui-amd64
  chmod 755 /home/container/vpn/vpn-ui-amd64`);
}
console.log('[install] launching full panel');
let entry = fs.readFileSync(root + '/entrypoint.sh', 'utf8');
entry = entry.replace(/(?<!\/home\/container)\/persistent/g, '/home/container/persistent');
entry = entry.replace(/^\s*node \/home\/container\/(?:ovpn|ws-tcp)-bridge\.js\s*&\s*$/gm, '');
if (!/^exec node \/home\/container\/index\.js\s*$/m.test(entry)) { console.error('[install] unsupported entrypoint'); process.exit(1); }
fs.writeFileSync(root + '/kata-entrypoint-prepare.sh', entry.replace(/^exec node \/home\/container\/index\.js\s*$/m, ': # bootstrap loads the same entrypoint in this process'), { mode: 0o700 });
run('prepare persistent state and sidecars', '/bin/sh /home/container/kata-entrypoint-prepare.sh');
require(root + '/index.js');
