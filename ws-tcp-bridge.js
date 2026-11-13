'use strict';
// WebSocket framing only; authentication, quotas and traffic accounting remain
// inside the existing managed Xray inbounds. Loopback only, no open proxy.
const http = require('http');
const net = require('net');
const WebSocket = require('./vendor/ws');

const targets = { '/railway-vmess': 21025, '/railway-trojan': 21002, '/railway-openvpn': 21023 };
// Unified per-user path ("/<subId>"): all WS configs of one user share a
// single path, so for those the target inbound is selected from the first
// payload bytes of the protocol handshake instead of from the path.
const TOKEN_PATH = /^\/[A-Za-z0-9_-]{8,64}$/;

function parseVlessHeader(buf) {
  if (!buf.length || buf[0] !== 0) return 'no';
  if (buf.length < 18) return 'incomplete';
  const addonLength = buf[17];
  if (addonLength > 64) return 'no';
  const cmdOffset = 18 + addonLength;
  if (buf.length < cmdOffset + 1) return 'incomplete';
  const command = buf[cmdOffset];
  // Command 3 = Mux / XUDP (used by Sing-box & Xray for UDP/DNS and Mux streams)
  if (command === 3) {
    if (buf.length < cmdOffset + 3) return 'incomplete';
    return 'valid';
  }
  if (command === 1 || command === 2) {
    if (buf.length < cmdOffset + 4) return 'incomplete';
    const port = buf.readUInt16BE(cmdOffset + 1);
    const addressType = buf[cmdOffset + 3];
    if (port < 1 || (addressType !== 1 && addressType !== 2 && addressType !== 3)) return 'no';
    return 'valid';
  }
  return 'no';
}

function isPotentialTrojanPrefix(buf) {
  const n = Math.min(buf.length, 56);
  for (let i = 0; i < n; i++) {
    const c = buf[i];
    const isHex = (c >= 48 && c <= 57) || (c >= 97 && c <= 102);
    if (!isHex) return false;
  }
  if (buf.length >= 57 && buf[56] !== 13) return false;
  if (buf.length >= 58 && buf[57] !== 10) return false;
  return true;
}

function classifyProtocol(buf) {
  // Trojan: 56 lowercase hex chars (SHA-224 of the password) + CRLF.
  if (buf.length >= 58
      && /^[0-9a-f]{56}$/.test(buf.subarray(0, 56).toString('ascii'))
      && buf[56] === 13 && buf[57] === 10) return 21002;
  // VLESS v0: TCP (1), UDP (2), and Mux/XUDP (3), with optional protobuf Addons.
  if (parseVlessHeader(buf) === 'valid') return 21001;
  // Everything else is VMess (AEAD header has no fixed marker).
  return 21025;
}

function decodeEarlyData(req, parsedUrl) {
  const ed = parseInt(parsedUrl.searchParams.get('ed') || '0', 10);
  const proto = req.headers['sec-websocket-protocol'];
  if (!(ed > 0) || !proto || typeof proto !== 'string') return null;
  const raw = proto.split(',')[0].trim();
  if (!raw || !/^[A-Za-z0-9_-]+$/.test(raw)) return null;
  try {
    const b64 = raw.replace(/-/g, '+').replace(/_/g, '/');
    const padded = b64 + '='.repeat((4 - (b64.length % 4)) % 4);
    const out = Buffer.from(padded, 'base64');
    return out.length ? out : null;
  } catch (_) {
    return null;
  }
}

function pipeTo(stream, port, firstChunk) {
  const upstream = net.createConnection({ host: '127.0.0.1', port });
  upstream.setNoDelay(true);
  if (firstChunk && firstChunk.length) upstream.write(firstChunk);
  upstream.on('error', () => stream.destroy());
  stream.on('error', () => upstream.destroy());
  upstream.on('close', () => stream.destroy());
  stream.on('close', () => upstream.destroy());
  stream.pipe(upstream).pipe(stream);
}

if (!global.__kbWsTcpBridgeStarted) {
global.__kbWsTcpBridgeStarted = true;
const server = http.createServer((req, res) => { res.writeHead(404); res.end(); });
const wss = new WebSocket.WebSocketServer({ noServer: true, perMessageDeflate: false, maxPayload: 16 * 1024 * 1024 });
server.on('upgrade', (req, socket, head) => {
  let parsedUrl;
  try { parsedUrl = new URL(req.url, 'http://localhost'); } catch (_) { socket.destroy(); return; }
  const pathname = parsedUrl.pathname;
  const fixedPort = targets[pathname];
  const isTokenPath = !fixedPort && TOKEN_PATH.test(pathname);
  if ((!fixedPort && !isTokenPath) || req.method !== 'GET') { socket.destroy(); return; }
  socket.setNoDelay(true);
  const earlyData = !fixedPort ? decodeEarlyData(req, parsedUrl) : null;
  wss.handleUpgrade(req, socket, head, (ws) => {
    const stream = WebSocket.createWebSocketStream(ws, { highWaterMark: 65536 });
    if (fixedPort) { pipeTo(stream, fixedPort, null); return; }
    let buffered = earlyData ? Buffer.from(earlyData) : Buffer.alloc(0);
    let decided = false;
    const decide = (port) => {
      if (decided) return;
      decided = true;
      clearTimeout(timer);
      stream.removeListener('data', onData);
      pipeTo(stream, port, buffered);
    };
    const tryClassify = () => {
      if (!buffered.length) return;
      const vlessState = parseVlessHeader(buffered);
      if (vlessState === 'valid') { decide(21001); return; }
      if (vlessState === 'incomplete') {
        if (buffered.length >= 96) decide(classifyProtocol(buffered));
        return;
      }
      if (buffered.length < 58 && isPotentialTrojanPrefix(buffered)) return;
      if (buffered.length >= 16) decide(classifyProtocol(buffered));
    };
    const onData = (chunk) => {
      buffered = buffered.length ? Buffer.concat([buffered, chunk]) : chunk;
      tryClassify();
    };
    const timer = setTimeout(() => decide(classifyProtocol(buffered)), 3000);
    stream.on('data', onData);
    stream.on('error', () => clearTimeout(timer));
    stream.on('close', () => clearTimeout(timer));
    if (buffered.length) tryClassify();
  });
});
server.on('error', (err) => { console.error('ws tcp bridge error:', err.message); });
server.listen(21130, '127.0.0.1', () => console.log('WS TCP bridge listening on 127.0.0.1:21130'));
}
